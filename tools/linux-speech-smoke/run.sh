#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux || "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'This explicit model preparation smoke runs only in coordinated remote Linux Actions.' >&2
  exit 2
fi
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${RUNNER_TEMP:?}/mouthtype-speech-XXXXXX")"
cleanup() {
  for result in report.json fixtures.json environment.txt; do
    if [[ -f "$work_dir/$result" ]]; then
      cp -- "$work_dir/$result" "${MOUTHTYPE_SMOKE_EVIDENCE:?}/$result"
    fi
  done
  if [[ -f "$work_dir/setup/setup-receipt.json" ]]; then
    cp -- "$work_dir/setup/setup-receipt.json" "$MOUTHTYPE_SMOKE_EVIDENCE/setup-receipt.json"
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
  cat /etc/os-release
  uname -srm
  lscpu
  free -b
  python3 --version
  pacman -Q python python-pip curl pipewire-audio espeak-ng sox glibc pacman archlinux-keyring
  pacman-conf SigLevel
} | tee "$work_dir/environment.txt"
python3 -m unittest discover -s "$repo_dir/tools/linux-speech-smoke" -p 'test_*.py'
python3 "$repo_dir/tools/linux-desktop/setup_speech.py" --destination "$work_dir/setup"
python3 - "$work_dir" "$repo_dir" <<'PY'
import json,pathlib,subprocess,sys,wave
work,repo=map(pathlib.Path,sys.argv[1:])
fixtures=json.loads((repo/'tools/linux-speech-smoke/fixtures.json').read_text())
expanded=[]
for fixture in fixtures:
    path=work/(fixture['id']+'.wav')
    if fixture['text']:
        raw=work/(fixture['id']+'-source.wav')
        subprocess.run(['espeak-ng','-v','en-us','-s','165','-w',str(raw),fixture['text']],check=True,timeout=10)
        subprocess.run(['sox',str(raw),'-r','16000','-c','1','-b','16','-e','signed-integer',str(path)],check=True,timeout=10)
    else:
        with wave.open(str(path),'wb') as silence:
            silence.setnchannels(1);silence.setsampwidth(2);silence.setframerate(16000);silence.writeframes(b'\0\0'*16000)
    expanded.append({**fixture,'wav':str(path)})
(work/'fixtures.json').write_text(json.dumps(expanded,indent=2))
PY
proof_exit=0
timeout --signal=TERM --kill-after=10s 360s "$work_dir/setup/venv/bin/python" "$repo_dir/tools/linux-engine-proof/proof.py" --config "$work_dir/setup/engines.json" --speech "$work_dir/fixtures.json" --startup-seconds 120 --request-seconds 45 --output "$work_dir/report.json" || proof_exit=$?
cat "$work_dir/report.json"
python3 "$repo_dir/tools/linux-speech-smoke/check_report.py" --report "$work_dir/report.json" --config "$work_dir/setup/engines.json" --fixtures "$work_dir/fixtures.json" --proof-exit "$proof_exit"
