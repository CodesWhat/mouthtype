# GNOME testbed notes

`Dockerfile` and `run.sh` are the headless GNOME 50 image (T1). `probe.Dockerfile` and `probe.sh` layer the portal probe on top (T2):

```bash
cd tools/linux-desktop
bash ~/scripts/nas-docker.sh build -t ld-t1-gnome:test testbed/gnome
bash ~/scripts/nas-docker.sh build -f testbed/gnome/probe.Dockerfile -t ld-t2-probe:test .
bash ~/scripts/nas-docker.sh run --rm --name ld-t2-gnome ld-t2-probe:test
```

`probe.json` is printed at the end. The GlobalShortcuts bind waits for GNOME Settings' consent dialog, which nobody answers headless, so it times out after 20s and the hold-versus-toggle latency stays unmeasured until the consent step is automated.
