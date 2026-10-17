#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux || "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'This disposable model proof runs only in the coordinated remote Linux Actions job.' >&2
  exit 2
fi
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${RUNNER_TEMP:?}/mouthtype-runtime-XXXXXX")"
cleanup() {
  if [[ -n "${MOUTHTYPE_SMOKE_EVIDENCE:-}" ]]; then
    for result in report.json fixtures.json environment.txt; do
      if [[ -f "$work_dir/$result" ]]; then
        cp -- "$work_dir/$result" "$MOUTHTYPE_SMOKE_EVIDENCE/$result"
      fi
    done
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pins="$repo_dir/tools/linux-engine-proof/pins.json"
read_pin() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$pins" "$1" "$2"
}
python3 -m unittest discover -s "$repo_dir/tools/linux-engine-proof" -p 'test_*.py'
python3 -m unittest discover -s "$repo_dir/tools/linux-runtime-smoke" -p 'test_*.py'
{
  cat /etc/os-release
  uname -srm
  lscpu
  free -b
  if command -v pacman >/dev/null; then
    pacman -Q cmake gcc git curl python espeak-ng sox glibc pacman archlinux-keyring
    pacman-conf SigLevel
  else
    dpkg-query -W cmake g++ git curl espeak-ng sox
  fi
  python3 --version
} | tee "$work_dir/environment.txt"
python3 -m venv "$work_dir/venv"
timeout --signal=TERM --kill-after=10s 180s "$work_dir/venv/bin/python" -m pip install --disable-pip-version-check --timeout 30 --retries 1 -r "$repo_dir/tools/linux-engine-proof/requirements.txt"
"$work_dir/venv/bin/python" -m pip freeze
llama_revision="$(read_pin llama revision)"
git init "$work_dir/llama"
git -C "$work_dir/llama" remote add origin https://github.com/ggml-org/llama.cpp.git
timeout --signal=TERM --kill-after=10s 120s git -C "$work_dir/llama" fetch --depth 1 origin "$llama_revision"
git -C "$work_dir/llama" checkout --detach FETCH_HEAD
[[ "$(git -C "$work_dir/llama" rev-parse HEAD)" == "$llama_revision" ]]
timeout --signal=TERM --kill-after=10s 60s cmake -S "$work_dir/llama" -B "$work_dir/llama/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
timeout --signal=TERM --kill-after=10s 900s cmake --build "$work_dir/llama/build" --target llama-server --parallel 2
"$work_dir/llama/build/bin/llama-server" --version
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --output "$work_dir/parakeet.tar.bz2" "$(read_pin parakeet source)"
printf '%s  %s\n' "$(read_pin parakeet sha256)" "$work_dir/parakeet.tar.bz2" | sha256sum --check -
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --output "$work_dir/s1.gguf" "$(read_pin s1 source)"
printf '%s  %s\n' "$(read_pin s1 sha256)" "$work_dir/s1.gguf" | sha256sum --check -
timeout --signal=TERM --kill-after=10s 60s tar --extract --file "$work_dir/parakeet.tar.bz2" --directory "$work_dir"
"$work_dir/venv/bin/python" "$repo_dir/tools/linux-engine-proof/prepare.py" --parakeet-archive "$work_dir/parakeet.tar.bz2" --parakeet-dir "$work_dir/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8" --s1 "$work_dir/s1.gguf" --server "$work_dir/llama/build/bin/llama-server" --output "$work_dir/config.json"
python3 - "$work_dir" "$repo_dir" <<'PY'
import json,pathlib,subprocess,sys,wave
work,repo=map(pathlib.Path,sys.argv[1:])
selection=json.loads((repo/'tools/linux-runtime-smoke/fixtures.json').read_text())
cleanup={case['id']:case for case in json.loads((repo/'Sources/mouthtype-bench/Fixtures/cleanup-cases.json').read_text())}
spoken=[]
for fixture in selection['speech']:
    path=work/(fixture['id']+'.wav')
    if fixture['text']:
        raw=work/(fixture['id']+'-source.wav')
        subprocess.run(['espeak-ng','-v','en-us','-s','165','-w',str(raw),fixture['text']],check=True,timeout=10)
        subprocess.run(['sox',str(raw),'-r','16000','-c','1','-b','16','-e','signed-integer',str(path)],check=True,timeout=10)
    else:
        with wave.open(str(path),'wb') as silence:
            silence.setnchannels(1);silence.setsampwidth(2);silence.setframerate(16000);silence.writeframes(b'\0\0'*16000)
    spoken.append({**fixture,'wav':str(path)})
expanded={'speech':spoken,'cleanup':[cleanup[name] for name in selection['cleanup']]}
(work/'fixtures.json').write_text(json.dumps(expanded,indent=2))
for task,cases in expanded.items():
    (work/(task+'.json')).write_text(json.dumps(cases,indent=2))
print(json.dumps({'synthetic_fixtures':expanded},indent=2))
PY
proof_exit=0
timeout --signal=TERM --kill-after=10s 480s "$work_dir/venv/bin/python" "$repo_dir/tools/linux-engine-proof/proof.py" --config "$work_dir/config.json" --speech "$work_dir/speech.json" --cleanup "$work_dir/cleanup.json" --startup-seconds 120 --request-seconds 45 --output "$work_dir/report.json" || proof_exit=$?
cat "$work_dir/report.json"
"$work_dir/venv/bin/python" "$repo_dir/tools/linux-runtime-smoke/check_report.py" --report "$work_dir/report.json" --config "$work_dir/config.json" --fixtures "$work_dir/fixtures.json" --proof-exit "$proof_exit"
