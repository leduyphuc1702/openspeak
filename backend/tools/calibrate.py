"""Calibrate the pronunciation scorer against expert ratings (speechocean762).

speechocean762 (OpenSLR 101, CC BY 4.0): 5000 utterances by non-native
speakers, each phone rated 0-2 and each word/sentence rated 0-10 by five
experts. Only adult speakers (age >= 18) are used.

L2-ARCTIC (manual subset, CC BY-NC 4.0; HF chikingsley/l2-arctic-manual-v5.0-16k)
marks each canonical phone of 24 non-native speakers (4 Vietnamese) as correct,
substituted or deleted. It is used only as an outside test: how well the phone
score separates mispronounced phones from correct ones (ROC AUC).

    python -m tools.calibrate extract --model M --dataset speechocean --split train   # slow: runs the model
    python -m tools.calibrate extract --model M --dataset speechocean --split test
    python -m tools.calibrate extract --model M --dataset l2arctic --split test       # also: validation
    python -m tools.calibrate extract --model M --dataset librispeech --split test-clean  # native control
    python -m tools.calibrate fit --model M        # report for one model
    python -m tools.calibrate compare --write      # all extracted models; best one -> app/calibration.json

`extract` caches raw per-phone GOP + similarity to calib/models/<M>/<dataset>-<split>.jsonl
and is resumable. `fit` tunes gop_scale / gop_weight on speechocean train, picks the
"good" threshold, and reports Pearson correlation on speechocean test before and after.
`compare` does that for every model on the utterances all of them could score.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.scoring import CALIBRATION_FILE, Assessor, Calibration, NoSpeechError  # noqa: E402
from app.phonetics import Lexicon, UnknownWordError  # noqa: E402

DATA = ROOT / "calib" / "speechocean762"
L2ARCTIC = ROOT / "calib" / "l2arctic"
LIBRISPEECH = ROOT / "calib" / "librispeech"
NATIVE_PER_SPEAKER = 10
CACHE = ROOT / "calib" / "models"
MIN_AGE = 18
# Our ids split stressed/unstressed AH and ER; L2-ARCTIC's canonical phones do not.
L2_ID = {"AX": "AH", "AXR": "ER"}


def model_dir(model: str) -> Path:
    return CACHE / model.replace("/", "__")


def model_name(path: Path) -> str:
    return path.name.replace("__", "/")


def adult_utterances(split: str) -> Iterator[Tuple[str, str, Path]]:
    ages = dict(line.split() for line in (DATA / split / "spk2age").read_text().splitlines() if line.strip())
    adults = {spk for spk, age in ages.items() if int(age) >= MIN_AGE}
    utt2spk = dict(line.split() for line in (DATA / split / "utt2spk").read_text().splitlines() if line.strip())
    wavs = dict(line.split() for line in (DATA / split / "wav.scp").read_text().splitlines() if line.strip())
    for utt, spk in sorted(utt2spk.items()):
        if spk in adults:
            yield utt, spk, DATA / wavs[utt]


def _cache(model: str, dataset: str, split: str) -> Path:
    path = model_dir(model) / f"{dataset}-{split}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _done(path: Path) -> set:
    if not path.exists():
        return set()
    return {json.loads(line)["utt"] for line in path.read_text().splitlines() if line.strip()}


def _phone_features(ours: Dict) -> List[List[Dict]]:
    return [[{"id": p["id"], "gop": p["gop"], "lpp": p["lpp"], "margin": p["margin"], "sim": p["similarity"]}
             for p in w["phones"]] for w in ours["words"]]


def _speechocean_items(split: str):
    import soundfile as sf

    scores = json.loads((DATA / "resource" / "scores.json").read_text())
    for utt, spk, wav_path in adult_utterances(split):
        ref = scores[utt]
        # Score against the exact phones the experts rated, not our CMUdict pick.
        lexicon = Lexicon({w["text"].lower(): [w["phones"]] for w in ref["words"]})
        record = {
            "utt": utt, "spk": spk,
            "expert": {k: ref[k] for k in ("accuracy", "fluency", "prosodic", "total", "completeness")},
            "expert_words": [{"accuracy": w["accuracy"], "stress": w["stress"], "phones": w["phones-accuracy"]}
                             for w in ref["words"]],
        }
        text = " ".join(w["text"] for w in ref["words"])
        yield utt, record, lambda p=wav_path: sf.read(str(p), dtype="float32")[0], text, lexicon


def _l2arctic_items(split: str):
    import io

    import pyarrow.parquet as pq
    import soundfile as sf

    lexicon = Lexicon()
    table = pq.read_table(L2ARCTIC / f"{split}.parquet",
                          columns=["audio", "speaker_id", "native_language", "utterance_id", "transcript", "manual_events"])
    for row in table.to_pylist():
        utt = f"{row['speaker_id']}_{row['utterance_id']}"
        canonical = [{"id": e["canonical_phoneme"], "error": e["error_type"], "heard": e["perceived_phoneme"]}
                     for e in row["manual_events"] if e["canonical_phoneme"]]
        record = {"utt": utt, "spk": row["speaker_id"], "l1": row["native_language"], "canonical": canonical}
        audio = row["audio"]["bytes"]
        yield utt, record, lambda b=audio: sf.read(io.BytesIO(b), dtype="float32")[0], row["transcript"], lexicon


def _librispeech_items(split: str):
    """Native control: the 10 shortest utterances (>= 6 words) of each test-clean speaker."""
    import io
    from collections import defaultdict

    import pyarrow.parquet as pq
    import soundfile as sf

    lexicon = Lexicon()
    meta = pq.read_table(LIBRISPEECH / f"{split}.parquet", columns=["id", "text", "speaker_id"]).to_pylist()
    by_speaker = defaultdict(list)
    for i, row in enumerate(meta):
        if len(row["text"].split()) >= 6:
            by_speaker[row["speaker_id"]].append((len(row["text"]), i))
    chosen = sorted(i for rows in by_speaker.values() for _, i in sorted(rows)[:NATIVE_PER_SPEAKER])
    table = pq.read_table(LIBRISPEECH / f"{split}.parquet", columns=["audio"])
    for i in chosen:
        row = meta[i]
        audio = table.column("audio")[i].as_py()["bytes"]
        record = {"utt": row["id"], "spk": str(row["speaker_id"])}
        yield row["id"], record, lambda b=audio: sf.read(io.BytesIO(b), dtype="float32")[0], row["text"].lower(), lexicon


def extract(model: str, dataset: str, split: str, limit: int) -> None:
    from app.recognizer import Wav2Vec2PhonemeRecognizer

    out_path = _cache(model, dataset, split)
    done = _done(out_path)
    items = {"speechocean": _speechocean_items, "l2arctic": _l2arctic_items,
             "librispeech": _librispeech_items}[dataset](split)
    recognizer = Wav2Vec2PhonemeRecognizer(model)
    print(f"{model} {dataset}/{split}: {len(done)} cached, running on {recognizer.device}", flush=True)
    t0, n = time.time(), 0
    with out_path.open("a") as out:
        for utt, record, read_wav, text, lexicon in items:
            if utt in done:
                continue
            if limit and n >= limit:
                break
            n += 1
            try:
                ours = Assessor(recognizer, lexicon, calibration=Calibration()).assess(read_wav(), text)
                record["scores"] = ours["scores"]
                record["words"] = _phone_features(ours)
            except (NoSpeechError, UnknownWordError, ValueError, KeyError) as e:
                record["error"] = f"{type(e).__name__}: {e}"
            out.write(json.dumps(record) + "\n")
            out.flush()
            if n % 100 == 0:
                print(f"  {n} done  {(time.time() - t0) / n:.2f}s/utt", flush=True)
    print("EXTRACT_OK", model, dataset, split, flush=True)


def _rows(model: str, dataset: str, split: str) -> List[Dict]:
    path = model_dir(model) / f"{dataset}-{split}.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def usable(model: str, split: str) -> Dict[str, Dict]:
    rows = _rows(model, "speechocean", split)
    return {r["utt"]: r for r in rows if "error" not in r and len(r["words"]) == len(r["expert_words"])
            and all(len(a) == len(b["phones"]) for a, b in zip(r["words"], r["expert_words"]))}


def load(model: str, split: str, keep: Optional[set] = None) -> List[Dict]:
    ok = usable(model, split)
    rows = [r for u, r in sorted(ok.items()) if keep is None or u in keep]
    print(f"  speechocean/{split}: {len(rows)} utterances ({len({r['spk'] for r in rows})} adult speakers)")
    return rows


def pearson(a, b) -> float:
    a, b = np.asarray(a, float), np.asarray(b, float)
    if a.size < 3 or a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def phone_arrays(rows: List[Dict]):
    feats, expert = [], []
    for r in rows:
        for ours, ref in zip(r["words"], r["expert_words"]):
            feats.extend(ours)
            expert.extend(ref["phones"])
    return feats, np.array(expert)


def phone_scores(feats: List[Dict], cal: Calibration) -> np.ndarray:
    return np.array([cal.phone_score(f, f["sim"]) for f in feats])


def evaluate(rows: List[Dict], cal: Calibration) -> Dict[str, float]:
    feats, expert = phone_arrays(rows)
    phone = phone_scores(feats, cal)
    word_ours, word_ref, utt_ours, utt_ref = [], [], [], []
    k = 0
    for r in rows:
        utt_scores = []
        for ours, ref in zip(r["words"], r["expert_words"]):
            ws = phone[k:k + len(ours)]
            k += len(ours)
            word_ours.append(ws.mean())
            word_ref.append(ref["accuracy"])
            utt_scores.extend(ws)
        utt_ours.append(np.mean(utt_scores))
        utt_ref.append(r["expert"]["accuracy"])
    return {
        "phone_pcc": pearson(phone, expert),
        "word_pcc": pearson(word_ours, word_ref),
        "utterance_pcc": pearson(utt_ours, utt_ref),
    }


def component_pcc(rows: List[Dict]) -> Dict[str, float]:
    pairs = {"fluency": "fluency", "intonation": "prosodic", "overall": "total"}
    out = {}
    for ours_key, ref_key in pairs.items():
        xs = [(r["scores"][ours_key], r["expert"][ref_key]) for r in rows if r["scores"].get(ours_key) is not None]
        out[f"{ours_key}_vs_{ref_key}_pcc"] = pearson([x for x, _ in xs], [y for _, y in xs]) if xs else float("nan")
    return out


def best_threshold(rows: List[Dict], cal: Calibration) -> Tuple[float, float]:
    """Threshold on phone score that best separates expert 'correct' (>= 1.5) from not, by balanced accuracy."""
    feats, expert = phone_arrays(rows)
    phone = phone_scores(feats, cal)
    correct = expert >= 1.5
    best = (80.0, 0.0)
    for t in np.arange(30, 99, 1.0):
        pred = phone >= t
        tpr = (pred & correct).sum() / max(correct.sum(), 1)
        tnr = (~pred & ~correct).sum() / max((~correct).sum(), 1)
        bal = (tpr + tnr) / 2
        if bal > best[1]:
            best = (float(t), float(bal))
    return best


def tune(train: List[Dict]) -> Tuple[Calibration, Dict]:
    """Grid-search feature / scale / weight on train, then fit the display map and the 'good' threshold."""
    feats, expert = phone_arrays(train)
    best, best_r, per_feature = Calibration(), -1.0, {}
    for feature in ("gop", "lpp", "margin"):
        for scale in [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0, 64.0]:
            for weight in np.round(np.arange(0.0, 1.01, 0.1), 2):
                cal = Calibration(gop_scale=scale, gop_weight=float(weight), feature=feature)
                r = pearson(phone_scores(feats, cal), expert)
                if r > per_feature.get(feature, (-1.0,))[0]:
                    per_feature[feature] = (r, scale, float(weight))
                if r > best_r:
                    best, best_r = cal, r
    raw = phone_scores(feats, best)
    gain, offset = np.polyfit(raw, 50.0 * expert, 1)
    best = Calibration(best.gop_scale, best.gop_weight, best.good_threshold, best.feature, float(gain), float(offset))
    threshold, bal_acc = best_threshold(train, best)
    tuned = Calibration(best.gop_scale, best.gop_weight, threshold, best.feature, best.display_gain, best.display_offset)
    info = {"train_phone_pcc_by_feature": {f: {"pcc": round(r, 3), "scale": sc, "weight": w}
                                           for f, (r, sc, w) in per_feature.items()},
            "train_balanced_accuracy_at_threshold": round(bal_acc, 3)}
    return tuned, info


def auc(scores: np.ndarray, positive: np.ndarray) -> float:
    """ROC AUC that a positive (mispronounced) phone scores lower than a correct one; ties count half."""
    pos, neg = -scores[positive], -scores[~positive]
    if pos.size == 0 or neg.size == 0:
        return float("nan")
    values = np.concatenate([pos, neg])
    order = np.argsort(values, kind="mergesort")
    ranks = np.empty(values.size)
    sorted_v = values[order]
    i = 0
    while i < values.size:
        j = i
        while j + 1 < values.size and sorted_v[j + 1] == sorted_v[i]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2 + 1
        i = j + 1
    u = ranks[:pos.size].sum() - pos.size * (pos.size + 1) / 2
    return float(u / (pos.size * neg.size))


def l2arctic_pairs(model: str, keep: Optional[set] = None) -> List[Tuple[Dict, bool, str, str]]:
    """(our phone features, annotator marked it wrong, speaker L1, canonical phone) for phones matched by id to the canonical sequence."""
    from difflib import SequenceMatcher

    pairs = []
    for split in ("validation", "test"):
        for r in _rows(model, "l2arctic", split):
            if "error" in r or (keep is not None and r["utt"] not in keep):
                continue
            ours = [p for w in r["words"] for p in w]
            a = [L2_ID.get(p["id"], p["id"]) for p in ours]
            b = [c["id"] for c in r["canonical"]]
            for block in SequenceMatcher(a=a, b=b, autojunk=False).get_matching_blocks():
                for k in range(block.size):
                    canon = r["canonical"][block.b + k]
                    pairs.append((ours[block.a + k], canon["error"] != "correct", r["l1"], canon["id"]))
    return pairs


def l2arctic_utts(model: str) -> set:
    return {r["utt"] for split in ("validation", "test") for r in _rows(model, "l2arctic", split) if "error" not in r}


def l2arctic_eval(model: str, cal: Calibration, keep: Optional[set] = None) -> Dict:
    pairs = l2arctic_pairs(model, keep)
    if not pairs:
        return {}
    scores = np.array([cal.phone_score(f, f["sim"]) for f, _, _, _ in pairs])
    wrong = np.array([w for _, w, _, _ in pairs])
    vi = np.array([l1 == "Vietnamese" for _, _, l1, _ in pairs])
    phone = np.array([p for _, _, _, p in pairs])
    by_phone = {}
    for p in sorted(set(phone[vi])):
        m = vi & (phone == p)
        if wrong[m].sum() >= 20 and (~wrong[m]).sum() >= 20:
            by_phone[p] = {"n": int(m.sum()), "error_rate": round(float(wrong[m].mean()), 2),
                           "auc": round(auc(scores[m], wrong[m]), 3)}
    pred = scores < cal.good_threshold
    tp, fp, fn = (pred & wrong).sum(), (pred & ~wrong).sum(), (~pred & wrong).sum()
    precision, recall = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    return {
        "phones": int(len(pairs)), "mispronounced_share": round(float(wrong.mean()), 3),
        "auc_all": round(auc(scores, wrong), 3),
        "auc_vietnamese": round(auc(scores[vi], wrong[vi]), 3),
        "vietnamese_phones": int(vi.sum()),
        "vietnamese_by_phone": dict(sorted(by_phone.items(), key=lambda kv: -kv[1]["error_rate"])),
        "detect_at_threshold": {"precision": round(float(precision), 3), "recall": round(float(recall), 3),
                                "f1": round(float(2 * precision * recall / max(precision + recall, 1e-9)), 3)},
    }


def native_eval(model: str, cal: Calibration, keep: Optional[set] = None) -> Dict:
    """Native speakers should almost never be told a sound is wrong."""
    rows = [r for r in _rows(model, "librispeech", "test-clean")
            if "error" not in r and (keep is None or r["utt"] in keep)]
    if not rows:
        return {}
    feats = [p for r in rows for w in r["words"] for p in w]
    scores = np.array([cal.phone_score(f, f["sim"]) for f in feats])
    utt = [np.mean([cal.phone_score(p, p["sim"]) for w in r["words"] for p in w]) for r in rows]
    return {"utterances": len(rows), "phones": len(feats),
            "flagged_share": round(float((scores < cal.good_threshold).mean()), 3),
            "median_utterance_score": round(float(np.median(utt)), 1)}


def native_utts(model: str) -> set:
    return {r["utt"] for r in _rows(model, "librispeech", "test-clean") if "error" not in r}


def report(model: str, keep_train=None, keep_test=None, keep_l2=None, keep_native=None) -> Tuple[Calibration, Dict]:
    print(model)
    train, test = load(model, "train", keep_train), load(model, "test", keep_test)
    tuned, info = tune(train)
    shown = phone_scores(phone_arrays(test)[0], tuned)
    out = {
        "model": model,
        "train_utterances": len(train), "test_utterances": len(test),
        "feature": tuned.feature, "gop_scale": tuned.gop_scale, "gop_weight": tuned.gop_weight,
        "display_gain": round(tuned.display_gain, 4), "display_offset": round(tuned.display_offset, 3),
        "good_threshold": tuned.good_threshold,
        "test_phone_score_percentiles_10_50_90": [round(float(np.percentile(shown, q)), 1) for q in (10, 50, 90)],
        "test_expert_phone_mean_x50": round(float(50 * phone_arrays(test)[1].mean()), 1),
        **info,
        "test_before": {k: round(v, 3) for k, v in evaluate(test, Calibration()).items()},
        "test_after": {k: round(v, 3) for k, v in evaluate(test, tuned).items()},
        "test_components_default": {k: round(v, 3) for k, v in component_pcc(test).items()},
        "l2arctic": l2arctic_eval(model, tuned, keep_l2),
        "native_librispeech": native_eval(model, tuned, keep_native),
    }
    return tuned, out


def fit(model: str) -> None:
    _, out = report(model)
    print(json.dumps(out, indent=2, ensure_ascii=False))


def compare(write: bool) -> None:
    models = sorted(model_name(p) for p in CACHE.iterdir()
                    if (p / "speechocean-train.jsonl").exists() and (p / "speechocean-test.jsonl").exists())
    # Same utterances for every model, so the numbers are comparable.
    keep_train = set.intersection(*(set(usable(m, "train")) for m in models))
    keep_test = set.intersection(*(set(usable(m, "test")) for m in models))
    l2_sets = [l2arctic_utts(m) for m in models if l2arctic_utts(m)]
    keep_l2 = set.intersection(*l2_sets) if len(l2_sets) == len(models) else None
    native_sets = [native_utts(m) for m in models if native_utts(m)]
    keep_native = set.intersection(*native_sets) if len(native_sets) == len(models) else None
    results = {m: report(m, keep_train, keep_test, keep_l2, keep_native) for m in models}
    table = []
    for m, (_, out) in results.items():
        l2 = out["l2arctic"]
        table.append({"model": m, "feature": out["feature"], **out["test_after"],
                      "fluency_pcc": out["test_components_default"]["fluency_vs_fluency_pcc"],
                      "l2arctic_auc": l2.get("auc_all"), "l2arctic_auc_vietnamese": l2.get("auc_vietnamese"),
                      "l2arctic_f1": l2.get("detect_at_threshold", {}).get("f1"),
                      "native_flagged": out["native_librispeech"].get("flagged_share")})
    table.sort(key=lambda row: -row["phone_pcc"])
    print(f"{'model':62s} {'feat':6s} phone  word   utt    flu    L2auc  L2vi   L2f1   native")
    for row in table:
        print(f"{row['model']:62s} {row['feature']:6s} " + "  ".join(
            f"{row[k]:.3f}" if isinstance(row[k], float) else "  -  "
            for k in ("phone_pcc", "word_pcc", "utterance_pcc", "fluency_pcc",
                      "l2arctic_auc", "l2arctic_auc_vietnamese", "l2arctic_f1", "native_flagged")))
    (ROOT / "calib" / "compare.json").write_text(json.dumps(
        {"train_utterances": len(keep_train), "test_utterances": len(keep_test),
         "l2arctic_utterances": len(keep_l2) if keep_l2 else 0,
         "native_utterances": len(keep_native) if keep_native else 0, "table": table,
         "details": {m: out for m, (_, out) in results.items()}}, indent=2, ensure_ascii=False) + "\n")
    if write:
        best = table[0]["model"]
        _, out = results[best]
        out = {"dataset": "speechocean762 (OpenSLR 101, CC BY 4.0), adult speakers only; "
                          "outside test: L2-ARCTIC manual subset (CC BY-NC 4.0)",
               **out, "model_comparison": table}
        CALIBRATION_FILE.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
        print("wrote", CALIBRATION_FILE, "model:", best)


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract")
    ex.add_argument("--model", required=True)
    ex.add_argument("--dataset", choices=["speechocean", "l2arctic", "librispeech"], default="speechocean")
    ex.add_argument("--split", choices=["train", "test", "validation", "test-clean"], required=True)
    ex.add_argument("--limit", type=int, default=0)
    ft = sub.add_parser("fit")
    ft.add_argument("--model", required=True)
    cp = sub.add_parser("compare")
    cp.add_argument("--write", action="store_true")
    args = ap.parse_args()
    if args.cmd == "extract":
        extract(args.model, args.dataset, args.split, args.limit)
    elif args.cmd == "fit":
        fit(args.model)
    else:
        compare(args.write)


if __name__ == "__main__":
    main()
