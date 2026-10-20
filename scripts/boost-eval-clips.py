#!/usr/bin/env python3
"""Builds the vocabulary-boosting evaluation clips with macOS `say` and writes manifest.json.

Usage: python3 scripts/boost-eval-clips.py /tmp/mouthtype-boost-eval

Each sentence is spoken by Samantha (en_US) and Daniel (en_GB), converted to 16 kHz mono WAV.
`names` sentences carry tricky spellings; `plain` sentences use ordinary words only. The distractor
list is names that never appear in any sentence, for the false-positive runs.
"""
import json
import subprocess
import sys
from pathlib import Path

VOICES = ["Samantha", "Daniel"]

NAMES = [
    ("Please send the invoice to Siobhan before Friday.", ["Siobhan"]),
    ("Doctor Nguyen will review the Kubernetes migration plan.", ["Nguyen", "Kubernetes"]),
    ("I opened a ticket for Mouthtype about the pill animation.", ["Mouthtype"]),
    ("Ask Ludacris whether the stage lights arrive on Tuesday.", ["Ludacris"]),
    ("Saoirse and Niamh are presenting the quarterly numbers.", ["Saoirse", "Niamh"]),
    ("Joaquin forwarded the Terraform changes to the team.", ["Joaquin", "Terraform"]),
    ("Xiomara said the Grafana dashboard is finally working.", ["Xiomara", "Grafana"]),
    ("Kowalczyk wants the Postgres backup moved to Monday.", ["Kowalczyk", "Postgres"]),
    ("Sockguard blocked the request before it reached Drydock.", ["Sockguard", "Drydock"]),
    ("The Parakeet model runs well next to FluidAudio.", ["Parakeet", "FluidAudio"]),
    ("We tried WhisperKit last week and then switched back.", ["WhisperKit"]),
    ("Anthropic published the update while Zhang was travelling.", ["Anthropic", "Zhang"]),
    ("Szymanski rewrote the Svelte component over the weekend.", ["Szymanski", "Svelte"]),
    ("Dhruv asked for the Tailwind config in the shared folder.", ["Dhruv", "Tailwind"]),
    ("Oluwaseun will join the call after the standup.", ["Oluwaseun"]),
    ("Bjorn and Thibault are driving to the conference together.", ["Bjorn", "Thibault"]),
    ("Cillian booked the room for the Kubernetes workshop.", ["Cillian", "Kubernetes"]),
    ("Remind me to email Siobhan about the Mouthtype release notes.", ["Siobhan", "Mouthtype"]),
    ("Nguyen found a bug in the Grafana alert rules.", ["Nguyen", "Grafana"]),
    ("Did Saoirse finish the Terraform review yet?", ["Saoirse", "Terraform"]),
    ("Drydock needs a new certificate before Thursday.", ["Drydock"]),
    ("Joaquin and Zhang are pairing on the Postgres upgrade.", ["Joaquin", "Zhang"]),
    ("Thibault sent the Sockguard logs to Dhruv this morning.", ["Thibault", "Sockguard", "Dhruv"]),
    ("Xiomara wants the Svelte demo ready by noon.", ["Xiomara", "Svelte"]),
    ("Bjorn thinks Anthropic will ship the feature soon.", ["Bjorn", "Anthropic"]),
]

PLAIN = [
    "Please send the invoice to the office before Friday.",
    "The doctor will review the new schedule this afternoon.",
    "I opened a ticket about the broken door on the second floor.",
    "Ask whether the stage lights arrive on Tuesday morning.",
    "We are presenting the quarterly numbers to the whole company.",
    "She forwarded the budget changes to the finance team.",
    "The dashboard finally works after the long weekend.",
    "He wants the backup moved to Monday because of the holiday.",
    "The request was blocked before it reached the server.",
    "The weather looks better next to the lake than in town.",
    "We tried the old recipe last week and then switched back.",
    "They published the update while the manager was travelling.",
    "She rewrote the report over the weekend and sent it around.",
    "Please put the meeting notes in the shared folder tonight.",
    "I will join the call right after the morning standup.",
    "They are driving to the conference together on Wednesday.",
    "Someone booked the room for the training workshop.",
    "Remind me to email the landlord about the lease renewal.",
    "He found a mistake in the delivery schedule yesterday.",
    "Did the team finish the final review yet?",
    "The car needs a new battery before the long trip.",
    "Both of them are working on the kitchen renovation.",
    "She sent the photographs to her brother this morning.",
    "I want the presentation ready by noon tomorrow.",
    "He thinks the store will open the new branch soon.",
]

DISTRACTORS = (
    "Aoife Bronwyn Caoimhe Declan Eamon Fionnuala Grainne Hamish Isolde Jorund Keiran Lorcan Maeve Niall Oisin "
    "Padraig Quillon Roisin Seamus Tadhg Ultan Venetia Wilhelmina Xanthe Yusuf Zainab Anneliese Baptiste Cosimo "
    "Dagmar Evander Fenella Gaspard Hortense Ignatius Jocasta Kazimir Leocadia Mortimer Nerys Octavia Percival "
    "Rosalind Sigrid Thaddeus Ursula Valentina Winifred Ximena Yolanda Zebediah Alasdair Brannigan Calloway "
    "Delacroix Eastwood Fairbanks Galloway Hargreaves Ironside Jamieson Kincaid Lockhart Montgomery Nightingale "
    "Oglethorpe Pemberton Quatermain Radcliffe Sinclair Thackeray Underwood Vandermeer Whitlock Yarborough "
    "Zielinski Abernathy Blackwood Cavendish Dunmore Ellsworth Fitzgerald Grenville Hawthorne Islington "
    "Kensington Lancaster Merriweather Northcott Ormerod Prendergast Ravenscroft Sutherland Trelawney Upton "
    "Vasquez Wetherby Yeoman Zimmerman Okonkwo Adeyemi Chukwuma Nwosu Abubakar Ferreira Goncalves Henriques "
    "Marques Nascimento Oliveira Pereira Quintela Rodrigues Teixeira Vasconcelos Amundsen Bergstrom Christoffersen "
    "Danielsson Eriksson Fjellstad Gustafsson Halvorsen Ingvarsson Johansen Kristiansen Lindqvist Magnusson "
    "Nordstrom Olofsson Pettersen Rasmussen Sorensen Thorvaldsen Wallenberg Ahmadi Bakhtiari Davoodi Esfahani "
    "Farahani Ghorbani Hosseini Jafari Karimi Lotfi Moradi Najafi Rahimi Sadeghi Tehrani Yazdani Zandi "
    "Elasticsearch Prometheus Ansible Jenkins Datadog Snowflake Databricks Cloudflare Fastly Vercel Netlify "
    "Supabase Firebase Mongoose Sequelize Redux Webpack Vite Rollup Babel Eslint Prettier Jest Cypress "
    "Playwright Storybook Figma Notion Linear Asana Trello Basecamp Zapier Segment Mixpanel Amplitude Sentry "
    "Rollbar Honeycomb Lightstep Terragrunt Pulumi Nomad Consul Vagrant Packer Istio Envoy Linkerd Traefik"
).split()


def say(voice: str, text: str, dest: Path) -> None:
    aiff = dest.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(dest)], check=True
    )
    aiff.unlink()


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    spoken = {w.lower() for text, _ in NAMES for w in text.replace(".", "").replace("?", "").split()}
    spoken |= {w.lower() for text in PLAIN for w in text.replace(".", "").replace("?", "").split()}
    distractors = []
    for name in DISTRACTORS:
        if name.lower() not in spoken and name.lower() not in {d.lower() for d in distractors}:
            distractors.append(name)
    assert len(distractors) >= 200, len(distractors)
    clips = []
    for voice in VOICES:
        for i, (text, targets) in enumerate(NAMES):
            name = f"names-{voice.lower()}-{i:02d}.wav"
            say(voice, text, out / name)
            clips.append({"file": name, "group": "names", "voice": voice, "text": text, "targets": targets})
        for i, text in enumerate(PLAIN):
            name = f"plain-{voice.lower()}-{i:02d}.wav"
            say(voice, text, out / name)
            clips.append({"file": name, "group": "plain", "voice": voice, "text": text, "targets": []})
    manifest = {"clips": clips, "distractors": distractors[:200]}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"{len(clips)} clips, {len(manifest['distractors'])} distractors in {out}")


if __name__ == "__main__":
    main()
