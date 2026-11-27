# Mouthtype engine benchmark

Machine: Apple M4 Pro, 48 GB, macOS Version 27.2.1 (Build 26B131), Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1). FluidAudio 0.18.3, WhisperKit 1.1.1.

Date: 2026-11-26. Corpus: `/tmp/bakeoff-corpus`. 3 timed runs per clip after 1 untimed warm-up.

## Summary

| Engine | Cold prepare (s) | Warm load (s) | First transcribe (ms) | Short-clip median (ms) | Overall RTFx | WER synthetic | WER real | Peak RSS (MB) | Peak footprint (MB) | Model size (MB) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 (multilingual) (`parakeet-tdt-v3`) | 228.3 (models already on disk) | 2.1 | 690 | 446 | 10.2 | 0.4% | 0.4% | 193 | 113 | 461 | ok |
| Parakeet Ultra 0.6B (v3 post-trained) (`parakeet-ultra`) | 94.2 (models already on disk) | 1.6 | 397 | 337 | 12.5 | 0.4% | 0.4% | 147 | 93 | 603 | ok |
| Nemotron Unified ASR 0.6B (offline, en) (`nemotron-unified`) | 71.2 (models already on disk) | 0.8 | 594 | 423 | 11.4 | 0.3% | 0.4% | 123 | 79 | 597 | ok |

Cold prepare is the first process for the engine: download plus load, with CoreML compile folded into load. Warm load is `prepare()` in a fresh process with the models already on disk. First transcribe is the first untimed transcription in the warm process, which absorbs any lazy CoreML specialization that `prepare()` did not. Short-clip median is the median of per-clip medians for clips of 10 s or less. Overall RTFx is total audio seconds over the summed per-clip median processing seconds. WER is corpus-level (total edits over total reference words) on the last timed run of each clip. Peak RSS is the warm process after loading and transcribing the whole corpus. Peak footprint is the same process's peak `phys_footprint` from `TASK_VM_INFO`, which also counts GPU-backed unified memory.

Engines marked `(models already on disk)` in the cold column had their files cached before this run, so their cold number is not a first-ever download.

## Per-clip results

### Parakeet TDT 0.6B v3 (multilingual)

| Clip | Set | Audio (s) | Median (ms) | p95 (ms) | RTFx | WER |
|---|---|---|---|---|---|---|
| custom-names-daniel-00 | custom | 2.8 | 413 | 1116 | 6.9 | 12.5% |
| custom-names-daniel-01 | custom | 3.3 | 659 | 996 | 5.0 | 37.5% |
| custom-names-daniel-02 | custom | 3.4 | 684 | 834 | 4.9 | 20.0% |
| custom-names-daniel-03 | custom | 3.3 | 624 | 1151 | 5.3 | 0.0% |
| custom-names-daniel-04 | custom | 3.0 | 675 | 786 | 4.4 | 25.0% |
| custom-names-daniel-05 | custom | 3.2 | 557 | 612 | 5.7 | 12.5% |
| custom-names-daniel-06 | custom | 3.4 | 390 | 720 | 8.8 | 12.5% |
| custom-names-daniel-07 | custom | 3.2 | 1020 | 1244 | 3.1 | 62.5% |
| custom-names-daniel-08 | custom | 3.2 | 919 | 1032 | 3.4 | 25.0% |
| custom-names-daniel-09 | custom | 3.2 | 862 | 1115 | 3.7 | 25.0% |
| custom-names-daniel-10 | custom | 3.2 | 739 | 813 | 4.3 | 0.0% |
| custom-names-daniel-11 | custom | 3.3 | 782 | 1057 | 4.2 | 25.0% |
| custom-names-daniel-12 | custom | 3.4 | 733 | 1278 | 4.6 | 12.5% |
| custom-names-daniel-13 | custom | 3.2 | 855 | 892 | 3.7 | 10.0% |
| custom-names-daniel-14 | custom | 2.8 | 603 | 801 | 4.7 | 75.0% |
| custom-names-daniel-15 | custom | 2.9 | 478 | 815 | 6.1 | 0.0% |
| custom-names-daniel-16 | custom | 2.7 | 438 | 675 | 6.3 | 37.5% |
| custom-names-daniel-17 | custom | 3.7 | 645 | 789 | 5.7 | 30.0% |
| custom-names-daniel-18 | custom | 2.8 | 365 | 573 | 7.8 | 11.1% |
| custom-names-daniel-19 | custom | 2.8 | 281 | 498 | 9.9 | 28.6% |
| custom-names-daniel-20 | custom | 2.8 | 560 | 788 | 5.0 | 14.3% |
| custom-names-daniel-21 | custom | 3.0 | 496 | 670 | 6.0 | 44.4% |
| custom-names-daniel-22 | custom | 2.9 | 484 | 719 | 6.0 | 44.4% |
| custom-names-daniel-23 | custom | 3.0 | 629 | 757 | 4.8 | 12.5% |
| custom-names-daniel-24 | custom | 3.0 | 430 | 692 | 7.0 | 0.0% |
| custom-names-samantha-00 | custom | 2.8 | 592 | 618 | 4.7 | 0.0% |
| custom-names-samantha-01 | custom | 3.1 | 416 | 628 | 7.4 | 25.0% |
| custom-names-samantha-02 | custom | 3.2 | 592 | 683 | 5.4 | 20.0% |
| custom-names-samantha-03 | custom | 3.2 | 634 | 1006 | 5.1 | 0.0% |
| custom-names-samantha-04 | custom | 2.9 | 414 | 422 | 7.0 | 25.0% |
| custom-names-samantha-05 | custom | 3.2 | 414 | 421 | 7.7 | 0.0% |
| custom-names-samantha-06 | custom | 3.4 | 391 | 638 | 8.6 | 12.5% |
| custom-names-samantha-07 | custom | 3.3 | 451 | 645 | 7.2 | 25.0% |
| custom-names-samantha-08 | custom | 3.2 | 548 | 604 | 5.9 | 25.0% |
| custom-names-samantha-09 | custom | 3.0 | 554 | 776 | 5.4 | 25.0% |
| custom-names-samantha-10 | custom | 3.0 | 648 | 659 | 4.6 | 11.1% |
| custom-names-samantha-11 | custom | 3.2 | 740 | 1091 | 4.3 | 25.0% |
| custom-names-samantha-12 | custom | 3.2 | 702 | 718 | 4.5 | 12.5% |
| custom-names-samantha-13 | custom | 3.0 | 638 | 718 | 4.7 | 10.0% |
| custom-names-samantha-14 | custom | 2.8 | 441 | 528 | 6.3 | 50.0% |
| custom-names-samantha-15 | custom | 2.9 | 473 | 614 | 6.1 | 0.0% |
| custom-names-samantha-16 | custom | 2.7 | 216 | 442 | 12.3 | 12.5% |
| custom-names-samantha-17 | custom | 3.7 | 477 | 539 | 7.7 | 20.0% |
| custom-names-samantha-18 | custom | 2.5 | 606 | 634 | 4.2 | 11.1% |
| custom-names-samantha-19 | custom | 2.7 | 343 | 421 | 7.9 | 14.3% |
| custom-names-samantha-20 | custom | 2.9 | 412 | 578 | 7.1 | 14.3% |
| custom-names-samantha-21 | custom | 3.0 | 538 | 609 | 5.6 | 22.2% |
| custom-names-samantha-22 | custom | 2.9 | 486 | 623 | 6.0 | 44.4% |
| custom-names-samantha-23 | custom | 2.8 | 283 | 388 | 9.8 | 25.0% |
| custom-names-samantha-24 | custom | 2.8 | 132 | 652 | 21.2 | 0.0% |
| custom-plain-daniel-00 | custom | 2.9 | 299 | 309 | 9.7 | 0.0% |
| custom-plain-daniel-01 | custom | 3.0 | 317 | 715 | 9.4 | 0.0% |
| custom-plain-daniel-02 | custom | 3.4 | 326 | 347 | 10.6 | 0.0% |
| custom-plain-daniel-03 | custom | 3.1 | 202 | 277 | 15.2 | 11.1% |
| custom-plain-daniel-04 | custom | 3.2 | 148 | 213 | 21.8 | 0.0% |
| custom-plain-daniel-05 | custom | 3.2 | 291 | 303 | 11.1 | 0.0% |
| custom-plain-daniel-06 | custom | 3.1 | 243 | 273 | 12.7 | 0.0% |
| custom-plain-daniel-07 | custom | 3.1 | 566 | 605 | 5.5 | 0.0% |
| custom-plain-daniel-08 | custom | 2.9 | 352 | 530 | 8.1 | 0.0% |
| custom-plain-daniel-09 | custom | 2.9 | 238 | 473 | 12.3 | 0.0% |
| custom-plain-daniel-10 | custom | 3.5 | 314 | 523 | 11.0 | 0.0% |
| custom-plain-daniel-11 | custom | 3.1 | 354 | 413 | 8.7 | 0.0% |
| custom-plain-daniel-12 | custom | 3.3 | 492 | 768 | 6.6 | 0.0% |
| custom-plain-daniel-13 | custom | 3.0 | 244 | 261 | 12.1 | 0.0% |
| custom-plain-daniel-14 | custom | 2.9 | 134 | 136 | 22.0 | 20.0% |
| custom-plain-daniel-15 | custom | 3.1 | 199 | 304 | 15.4 | 0.0% |
| custom-plain-daniel-16 | custom | 2.6 | 206 | 392 | 12.7 | 0.0% |
| custom-plain-daniel-17 | custom | 3.2 | 478 | 532 | 6.7 | 0.0% |
| custom-plain-daniel-18 | custom | 3.1 | 582 | 630 | 5.2 | 0.0% |
| custom-plain-daniel-19 | custom | 2.5 | 279 | 382 | 8.9 | 0.0% |
| custom-plain-daniel-20 | custom | 2.8 | 294 | 547 | 9.5 | 0.0% |
| custom-plain-daniel-21 | custom | 2.8 | 412 | 426 | 6.8 | 0.0% |
| custom-plain-daniel-22 | custom | 2.9 | 517 | 607 | 5.6 | 0.0% |
| custom-plain-daniel-23 | custom | 2.9 | 606 | 627 | 4.8 | 0.0% |
| custom-plain-daniel-24 | custom | 2.9 | 494 | 531 | 5.9 | 0.0% |
| custom-plain-samantha-00 | custom | 2.9 | 535 | 705 | 5.4 | 0.0% |
| custom-plain-samantha-01 | custom | 2.8 | 226 | 354 | 12.6 | 0.0% |
| custom-plain-samantha-02 | custom | 3.2 | 763 | 781 | 4.3 | 0.0% |
| custom-plain-samantha-03 | custom | 3.0 | 441 | 700 | 6.7 | 0.0% |
| custom-plain-samantha-04 | custom | 3.1 | 357 | 635 | 8.8 | 0.0% |
| custom-plain-samantha-05 | custom | 3.1 | 315 | 326 | 9.8 | 0.0% |
| custom-plain-samantha-06 | custom | 2.9 | 457 | 611 | 6.3 | 0.0% |
| custom-plain-samantha-07 | custom | 3.2 | 551 | 889 | 5.8 | 0.0% |
| custom-plain-samantha-08 | custom | 2.8 | 435 | 518 | 6.3 | 0.0% |
| custom-plain-samantha-09 | custom | 2.7 | 664 | 683 | 4.0 | 0.0% |
| custom-plain-samantha-10 | custom | 3.3 | 636 | 1234 | 5.1 | 0.0% |
| custom-plain-samantha-11 | custom | 3.0 | 725 | 745 | 4.2 | 11.1% |
| custom-plain-samantha-12 | custom | 3.1 | 688 | 745 | 4.5 | 0.0% |
| custom-plain-samantha-13 | custom | 2.9 | 578 | 634 | 5.0 | 0.0% |
| custom-plain-samantha-14 | custom | 2.9 | 363 | 510 | 8.0 | 20.0% |
| custom-plain-samantha-15 | custom | 2.9 | 379 | 514 | 7.5 | 0.0% |
| custom-plain-samantha-16 | custom | 2.6 | 290 | 435 | 8.9 | 0.0% |
| custom-plain-samantha-17 | custom | 3.1 | 367 | 430 | 8.5 | 0.0% |
| custom-plain-samantha-18 | custom | 3.0 | 200 | 221 | 15.2 | 0.0% |
| custom-plain-samantha-19 | custom | 2.4 | 267 | 502 | 8.9 | 0.0% |
| custom-plain-samantha-20 | custom | 2.7 | 439 | 473 | 6.1 | 0.0% |
| custom-plain-samantha-21 | custom | 2.6 | 294 | 385 | 8.9 | 0.0% |
| custom-plain-samantha-22 | custom | 2.8 | 352 | 482 | 7.9 | 0.0% |
| custom-plain-samantha-23 | custom | 2.7 | 241 | 392 | 11.4 | 0.0% |
| custom-plain-samantha-24 | custom | 2.6 | 446 | 468 | 5.8 | 0.0% |
| real-6930-75918-0000 | real | 3.5 | 212 | 535 | 16.5 | 0.0% |
| real-6930-75918-0001 | real | 14.2 | 1334 | 1404 | 10.7 | 0.0% |
| real-6930-75918-0002 | real | 5.0 | 504 | 595 | 10.0 | 0.0% |
| real-6930-75918-0003 | real | 23.3 | 1599 | 1657 | 14.6 | 0.0% |
| real-6930-75918-0004 | real | 11.1 | 893 | 917 | 12.4 | 3.2% |
| real-6930-75918-0005 | real | 13.2 | 739 | 766 | 17.8 | 0.0% |
| real-6930-75918-0006 | real | 5.8 | 314 | 1231 | 18.6 | 0.0% |
| real-6930-75918-0007 | real | 3.3 | 280 | 361 | 11.8 | 0.0% |
| real-6930-75918-0008 | real | 4.8 | 141 | 350 | 34.0 | 0.0% |
| real-6930-75918-0009 | real | 7.3 | 557 | 562 | 13.1 | 0.0% |
| synthetic-01-clean | synthetic | 14.8 | 1395 | 1724 | 10.6 | 2.0% |
| synthetic-02-noise20 | synthetic | 14.8 | 2360 | 2396 | 6.3 | 2.0% |
| synthetic-03-noise10 | synthetic | 14.8 | 892 | 1049 | 16.6 | 4.1% |
| synthetic-04-long | synthetic | 211.9 | 8097 | 8836 | 26.2 | 0.0% |
| synthetic-1-slack-2s | synthetic | 2.0 | 141 | 318 | 14.1 | 0.0% |
| synthetic-2-slack-5s | synthetic | 5.4 | 460 | 502 | 11.8 | 0.0% |
| synthetic-3-review-10s | synthetic | 9.6 | 860 | 948 | 11.2 | 0.0% |
| synthetic-4-email-20s | synthetic | 19.1 | 1815 | 2266 | 10.6 | 0.0% |
| synthetic-5-email-45s | synthetic | 45.5 | 2055 | 2512 | 22.1 | 0.0% |

### Parakeet Ultra 0.6B (v3 post-trained)

| Clip | Set | Audio (s) | Median (ms) | p95 (ms) | RTFx | WER |
|---|---|---|---|---|---|---|
| custom-names-daniel-00 | custom | 2.8 | 501 | 526 | 5.7 | 12.5% |
| custom-names-daniel-01 | custom | 3.3 | 412 | 440 | 8.0 | 37.5% |
| custom-names-daniel-02 | custom | 3.4 | 614 | 620 | 5.5 | 20.0% |
| custom-names-daniel-03 | custom | 3.3 | 520 | 653 | 6.4 | 0.0% |
| custom-names-daniel-04 | custom | 3.0 | 729 | 753 | 4.1 | 25.0% |
| custom-names-daniel-05 | custom | 3.2 | 437 | 450 | 7.3 | 12.5% |
| custom-names-daniel-06 | custom | 3.4 | 521 | 644 | 6.6 | 12.5% |
| custom-names-daniel-07 | custom | 3.2 | 927 | 1281 | 3.4 | 50.0% |
| custom-names-daniel-08 | custom | 3.2 | 1318 | 1387 | 2.4 | 25.0% |
| custom-names-daniel-09 | custom | 3.2 | 744 | 1029 | 4.3 | 37.5% |
| custom-names-daniel-10 | custom | 3.2 | 514 | 1240 | 6.2 | 22.2% |
| custom-names-daniel-11 | custom | 3.3 | 761 | 827 | 4.3 | 25.0% |
| custom-names-daniel-12 | custom | 3.4 | 1144 | 1419 | 2.9 | 12.5% |
| custom-names-daniel-13 | custom | 3.2 | 329 | 484 | 9.7 | 10.0% |
| custom-names-daniel-14 | custom | 2.8 | 506 | 834 | 5.6 | 75.0% |
| custom-names-daniel-15 | custom | 2.9 | 717 | 886 | 4.1 | 11.1% |
| custom-names-daniel-16 | custom | 2.7 | 631 | 989 | 4.3 | 37.5% |
| custom-names-daniel-17 | custom | 3.7 | 868 | 1047 | 4.3 | 30.0% |
| custom-names-daniel-18 | custom | 2.8 | 599 | 967 | 4.8 | 11.1% |
| custom-names-daniel-19 | custom | 2.8 | 660 | 690 | 4.2 | 14.3% |
| custom-names-daniel-20 | custom | 2.8 | 1205 | 1206 | 2.3 | 14.3% |
| custom-names-daniel-21 | custom | 3.0 | 792 | 821 | 3.7 | 33.3% |
| custom-names-daniel-22 | custom | 2.9 | 761 | 925 | 3.8 | 33.3% |
| custom-names-daniel-23 | custom | 3.0 | 319 | 1408 | 9.4 | 12.5% |
| custom-names-daniel-24 | custom | 3.0 | 617 | 642 | 4.9 | 0.0% |
| custom-names-samantha-00 | custom | 2.8 | 712 | 896 | 3.9 | 0.0% |
| custom-names-samantha-01 | custom | 3.1 | 830 | 1003 | 3.7 | 25.0% |
| custom-names-samantha-02 | custom | 3.2 | 737 | 980 | 4.4 | 20.0% |
| custom-names-samantha-03 | custom | 3.2 | 835 | 1306 | 3.8 | 11.1% |
| custom-names-samantha-04 | custom | 2.9 | 871 | 1189 | 3.3 | 25.0% |
| custom-names-samantha-05 | custom | 3.2 | 886 | 1532 | 3.6 | 0.0% |
| custom-names-samantha-06 | custom | 3.4 | 614 | 991 | 5.5 | 12.5% |
| custom-names-samantha-07 | custom | 3.3 | 528 | 953 | 6.2 | 12.5% |
| custom-names-samantha-08 | custom | 3.2 | 475 | 518 | 6.8 | 12.5% |
| custom-names-samantha-09 | custom | 3.0 | 607 | 757 | 4.9 | 25.0% |
| custom-names-samantha-10 | custom | 3.0 | 305 | 633 | 9.7 | 0.0% |
| custom-names-samantha-11 | custom | 3.2 | 599 | 779 | 5.3 | 25.0% |
| custom-names-samantha-12 | custom | 3.2 | 576 | 634 | 5.5 | 12.5% |
| custom-names-samantha-13 | custom | 3.0 | 578 | 722 | 5.2 | 10.0% |
| custom-names-samantha-14 | custom | 2.8 | 590 | 634 | 4.7 | 50.0% |
| custom-names-samantha-15 | custom | 2.9 | 511 | 524 | 5.6 | 0.0% |
| custom-names-samantha-16 | custom | 2.7 | 230 | 447 | 11.6 | 12.5% |
| custom-names-samantha-17 | custom | 3.7 | 388 | 458 | 9.5 | 20.0% |
| custom-names-samantha-18 | custom | 2.5 | 323 | 681 | 7.8 | 11.1% |
| custom-names-samantha-19 | custom | 2.7 | 305 | 616 | 8.9 | 14.3% |
| custom-names-samantha-20 | custom | 2.9 | 440 | 520 | 6.7 | 0.0% |
| custom-names-samantha-21 | custom | 3.0 | 426 | 501 | 7.1 | 0.0% |
| custom-names-samantha-22 | custom | 2.9 | 318 | 505 | 9.2 | 44.4% |
| custom-names-samantha-23 | custom | 2.8 | 445 | 583 | 6.2 | 12.5% |
| custom-names-samantha-24 | custom | 2.8 | 476 | 618 | 5.9 | 0.0% |
| custom-plain-daniel-00 | custom | 2.9 | 439 | 631 | 6.6 | 0.0% |
| custom-plain-daniel-01 | custom | 3.0 | 336 | 440 | 8.9 | 0.0% |
| custom-plain-daniel-02 | custom | 3.4 | 299 | 774 | 11.5 | 0.0% |
| custom-plain-daniel-03 | custom | 3.1 | 533 | 537 | 5.7 | 11.1% |
| custom-plain-daniel-04 | custom | 3.2 | 177 | 565 | 18.2 | 0.0% |
| custom-plain-daniel-05 | custom | 3.2 | 466 | 620 | 6.9 | 0.0% |
| custom-plain-daniel-06 | custom | 3.1 | 422 | 507 | 7.3 | 0.0% |
| custom-plain-daniel-07 | custom | 3.1 | 426 | 658 | 7.3 | 0.0% |
| custom-plain-daniel-08 | custom | 2.9 | 111 | 112 | 25.7 | 0.0% |
| custom-plain-daniel-09 | custom | 2.9 | 252 | 376 | 11.6 | 0.0% |
| custom-plain-daniel-10 | custom | 3.5 | 543 | 738 | 6.4 | 0.0% |
| custom-plain-daniel-11 | custom | 3.1 | 284 | 484 | 10.9 | 11.1% |
| custom-plain-daniel-12 | custom | 3.3 | 273 | 762 | 12.0 | 0.0% |
| custom-plain-daniel-13 | custom | 3.0 | 337 | 540 | 8.8 | 0.0% |
| custom-plain-daniel-14 | custom | 2.9 | 321 | 489 | 9.2 | 20.0% |
| custom-plain-daniel-15 | custom | 3.1 | 164 | 596 | 18.6 | 0.0% |
| custom-plain-daniel-16 | custom | 2.6 | 202 | 540 | 12.9 | 0.0% |
| custom-plain-daniel-17 | custom | 3.2 | 143 | 505 | 22.4 | 0.0% |
| custom-plain-daniel-18 | custom | 3.1 | 394 | 449 | 7.8 | 0.0% |
| custom-plain-daniel-19 | custom | 2.5 | 157 | 298 | 15.8 | 0.0% |
| custom-plain-daniel-20 | custom | 2.8 | 192 | 201 | 14.5 | 0.0% |
| custom-plain-daniel-21 | custom | 2.8 | 130 | 253 | 21.7 | 0.0% |
| custom-plain-daniel-22 | custom | 2.9 | 104 | 393 | 27.8 | 0.0% |
| custom-plain-daniel-23 | custom | 2.9 | 174 | 218 | 16.8 | 0.0% |
| custom-plain-daniel-24 | custom | 2.9 | 183 | 301 | 15.8 | 0.0% |
| custom-plain-samantha-00 | custom | 2.9 | 238 | 426 | 12.1 | 0.0% |
| custom-plain-samantha-01 | custom | 2.8 | 231 | 324 | 12.3 | 0.0% |
| custom-plain-samantha-02 | custom | 3.2 | 357 | 569 | 9.1 | 0.0% |
| custom-plain-samantha-03 | custom | 3.0 | 212 | 331 | 14.0 | 0.0% |
| custom-plain-samantha-04 | custom | 3.1 | 147 | 269 | 21.3 | 0.0% |
| custom-plain-samantha-05 | custom | 3.1 | 251 | 294 | 12.3 | 0.0% |
| custom-plain-samantha-06 | custom | 2.9 | 72 | 139 | 40.2 | 0.0% |
| custom-plain-samantha-07 | custom | 3.2 | 126 | 274 | 25.6 | 0.0% |
| custom-plain-samantha-08 | custom | 2.8 | 93 | 94 | 29.5 | 0.0% |
| custom-plain-samantha-09 | custom | 2.7 | 132 | 158 | 20.3 | 0.0% |
| custom-plain-samantha-10 | custom | 3.3 | 81 | 105 | 40.2 | 0.0% |
| custom-plain-samantha-11 | custom | 3.0 | 209 | 212 | 14.5 | 11.1% |
| custom-plain-samantha-12 | custom | 3.1 | 170 | 197 | 18.1 | 0.0% |
| custom-plain-samantha-13 | custom | 2.9 | 243 | 268 | 11.8 | 0.0% |
| custom-plain-samantha-14 | custom | 2.9 | 93 | 285 | 31.2 | 20.0% |
| custom-plain-samantha-15 | custom | 2.9 | 199 | 211 | 14.4 | 0.0% |
| custom-plain-samantha-16 | custom | 2.6 | 223 | 487 | 11.5 | 0.0% |
| custom-plain-samantha-17 | custom | 3.1 | 231 | 266 | 13.5 | 0.0% |
| custom-plain-samantha-18 | custom | 3.0 | 144 | 227 | 21.1 | 0.0% |
| custom-plain-samantha-19 | custom | 2.4 | 153 | 181 | 15.6 | 0.0% |
| custom-plain-samantha-20 | custom | 2.7 | 167 | 180 | 16.1 | 0.0% |
| custom-plain-samantha-21 | custom | 2.6 | 222 | 379 | 11.7 | 0.0% |
| custom-plain-samantha-22 | custom | 2.8 | 157 | 162 | 17.6 | 0.0% |
| custom-plain-samantha-23 | custom | 2.7 | 98 | 185 | 28.0 | 0.0% |
| custom-plain-samantha-24 | custom | 2.6 | 91 | 342 | 28.3 | 0.0% |
| real-6930-75918-0000 | real | 3.5 | 159 | 189 | 22.0 | 0.0% |
| real-6930-75918-0001 | real | 14.2 | 481 | 623 | 29.6 | 0.0% |
| real-6930-75918-0002 | real | 5.0 | 227 | 369 | 22.2 | 0.0% |
| real-6930-75918-0003 | real | 23.3 | 801 | 878 | 29.1 | 0.0% |
| real-6930-75918-0004 | real | 11.1 | 484 | 718 | 22.8 | 3.2% |
| real-6930-75918-0005 | real | 13.2 | 609 | 780 | 21.6 | 0.0% |
| real-6930-75918-0006 | real | 5.8 | 434 | 449 | 13.5 | 0.0% |
| real-6930-75918-0007 | real | 3.3 | 136 | 149 | 24.4 | 0.0% |
| real-6930-75918-0008 | real | 4.8 | 154 | 219 | 31.1 | 0.0% |
| real-6930-75918-0009 | real | 7.3 | 393 | 480 | 18.5 | 0.0% |
| synthetic-01-clean | synthetic | 14.8 | 548 | 599 | 27.0 | 2.0% |
| synthetic-02-noise20 | synthetic | 14.8 | 869 | 1040 | 17.0 | 2.0% |
| synthetic-03-noise10 | synthetic | 14.8 | 575 | 664 | 25.7 | 4.1% |
| synthetic-04-long | synthetic | 211.9 | 5810 | 8896 | 36.5 | 0.0% |
| synthetic-1-slack-2s | synthetic | 2.0 | 124 | 263 | 16.1 | 0.0% |
| synthetic-2-slack-5s | synthetic | 5.4 | 175 | 216 | 31.0 | 0.0% |
| synthetic-3-review-10s | synthetic | 9.6 | 653 | 677 | 14.7 | 0.0% |
| synthetic-4-email-20s | synthetic | 19.1 | 1321 | 1454 | 14.5 | 0.0% |
| synthetic-5-email-45s | synthetic | 45.5 | 2224 | 2245 | 20.4 | 0.0% |

### Nemotron Unified ASR 0.6B (offline, en)

| Clip | Set | Audio (s) | Median (ms) | p95 (ms) | RTFx | WER |
|---|---|---|---|---|---|---|
| custom-names-daniel-00 | custom | 2.8 | 558 | 657 | 5.1 | 12.5% |
| custom-names-daniel-01 | custom | 3.3 | 458 | 787 | 7.2 | 50.0% |
| custom-names-daniel-02 | custom | 3.4 | 602 | 609 | 5.6 | 20.0% |
| custom-names-daniel-03 | custom | 3.3 | 386 | 546 | 8.6 | 11.1% |
| custom-names-daniel-04 | custom | 3.0 | 461 | 469 | 6.5 | 37.5% |
| custom-names-daniel-05 | custom | 3.2 | 598 | 852 | 5.3 | 25.0% |
| custom-names-daniel-06 | custom | 3.4 | 508 | 596 | 6.8 | 12.5% |
| custom-names-daniel-07 | custom | 3.2 | 488 | 662 | 6.5 | 50.0% |
| custom-names-daniel-08 | custom | 3.2 | 525 | 615 | 6.0 | 25.0% |
| custom-names-daniel-09 | custom | 3.2 | 166 | 216 | 19.2 | 37.5% |
| custom-names-daniel-10 | custom | 3.2 | 423 | 479 | 7.6 | 22.2% |
| custom-names-daniel-11 | custom | 3.3 | 619 | 642 | 5.3 | 25.0% |
| custom-names-daniel-12 | custom | 3.4 | 816 | 906 | 4.1 | 25.0% |
| custom-names-daniel-13 | custom | 3.2 | 694 | 814 | 4.6 | 10.0% |
| custom-names-daniel-14 | custom | 2.8 | 652 | 689 | 4.3 | 50.0% |
| custom-names-daniel-15 | custom | 2.9 | 544 | 645 | 5.4 | 0.0% |
| custom-names-daniel-16 | custom | 2.7 | 555 | 576 | 4.9 | 37.5% |
| custom-names-daniel-17 | custom | 3.7 | 423 | 552 | 8.8 | 30.0% |
| custom-names-daniel-18 | custom | 2.8 | 292 | 388 | 9.7 | 22.2% |
| custom-names-daniel-19 | custom | 2.8 | 365 | 447 | 7.6 | 14.3% |
| custom-names-daniel-20 | custom | 2.8 | 501 | 541 | 5.6 | 14.3% |
| custom-names-daniel-21 | custom | 3.0 | 605 | 672 | 4.9 | 44.4% |
| custom-names-daniel-22 | custom | 2.9 | 165 | 243 | 17.6 | 33.3% |
| custom-names-daniel-23 | custom | 3.0 | 801 | 1147 | 3.8 | 25.0% |
| custom-names-daniel-24 | custom | 3.0 | 780 | 1135 | 3.9 | 0.0% |
| custom-names-samantha-00 | custom | 2.8 | 561 | 669 | 4.9 | 12.5% |
| custom-names-samantha-01 | custom | 3.1 | 534 | 602 | 5.8 | 25.0% |
| custom-names-samantha-02 | custom | 3.2 | 604 | 794 | 5.3 | 20.0% |
| custom-names-samantha-03 | custom | 3.2 | 423 | 455 | 7.6 | 11.1% |
| custom-names-samantha-04 | custom | 2.9 | 290 | 349 | 9.9 | 25.0% |
| custom-names-samantha-05 | custom | 3.2 | 257 | 422 | 12.4 | 0.0% |
| custom-names-samantha-06 | custom | 3.4 | 555 | 698 | 6.1 | 12.5% |
| custom-names-samantha-07 | custom | 3.3 | 488 | 560 | 6.7 | 25.0% |
| custom-names-samantha-08 | custom | 3.2 | 370 | 442 | 8.7 | 12.5% |
| custom-names-samantha-09 | custom | 3.0 | 359 | 640 | 8.3 | 25.0% |
| custom-names-samantha-10 | custom | 3.0 | 591 | 649 | 5.0 | 22.2% |
| custom-names-samantha-11 | custom | 3.2 | 477 | 544 | 6.7 | 25.0% |
| custom-names-samantha-12 | custom | 3.2 | 819 | 878 | 3.9 | 25.0% |
| custom-names-samantha-13 | custom | 3.0 | 276 | 431 | 10.9 | 10.0% |
| custom-names-samantha-14 | custom | 2.8 | 495 | 539 | 5.6 | 50.0% |
| custom-names-samantha-15 | custom | 2.9 | 490 | 608 | 5.9 | 0.0% |
| custom-names-samantha-16 | custom | 2.7 | 448 | 621 | 5.9 | 12.5% |
| custom-names-samantha-17 | custom | 3.7 | 426 | 500 | 8.6 | 30.0% |
| custom-names-samantha-18 | custom | 2.5 | 400 | 558 | 6.3 | 11.1% |
| custom-names-samantha-19 | custom | 2.7 | 281 | 670 | 9.7 | 14.3% |
| custom-names-samantha-20 | custom | 2.9 | 387 | 881 | 7.6 | 0.0% |
| custom-names-samantha-21 | custom | 3.0 | 314 | 448 | 9.7 | 11.1% |
| custom-names-samantha-22 | custom | 2.9 | 335 | 396 | 8.8 | 33.3% |
| custom-names-samantha-23 | custom | 2.8 | 873 | 900 | 3.2 | 25.0% |
| custom-names-samantha-24 | custom | 2.8 | 539 | 552 | 5.2 | 0.0% |
| custom-plain-daniel-00 | custom | 2.9 | 265 | 292 | 10.9 | 0.0% |
| custom-plain-daniel-01 | custom | 3.0 | 564 | 693 | 5.3 | 0.0% |
| custom-plain-daniel-02 | custom | 3.4 | 565 | 567 | 6.1 | 0.0% |
| custom-plain-daniel-03 | custom | 3.1 | 532 | 752 | 5.8 | 11.1% |
| custom-plain-daniel-04 | custom | 3.2 | 271 | 527 | 11.9 | 0.0% |
| custom-plain-daniel-05 | custom | 3.2 | 345 | 405 | 9.4 | 0.0% |
| custom-plain-daniel-06 | custom | 3.1 | 542 | 623 | 5.7 | 0.0% |
| custom-plain-daniel-07 | custom | 3.1 | 936 | 1015 | 3.3 | 0.0% |
| custom-plain-daniel-08 | custom | 2.9 | 517 | 696 | 5.5 | 0.0% |
| custom-plain-daniel-09 | custom | 2.9 | 706 | 831 | 4.1 | 0.0% |
| custom-plain-daniel-10 | custom | 3.5 | 866 | 876 | 4.0 | 0.0% |
| custom-plain-daniel-11 | custom | 3.1 | 619 | 958 | 5.0 | 11.1% |
| custom-plain-daniel-12 | custom | 3.3 | 401 | 551 | 8.1 | 0.0% |
| custom-plain-daniel-13 | custom | 3.0 | 447 | 499 | 6.6 | 0.0% |
| custom-plain-daniel-14 | custom | 2.9 | 448 | 494 | 6.6 | 20.0% |
| custom-plain-daniel-15 | custom | 3.1 | 726 | 730 | 4.2 | 0.0% |
| custom-plain-daniel-16 | custom | 2.6 | 473 | 678 | 5.5 | 0.0% |
| custom-plain-daniel-17 | custom | 3.2 | 504 | 664 | 6.3 | 0.0% |
| custom-plain-daniel-18 | custom | 3.1 | 622 | 715 | 4.9 | 0.0% |
| custom-plain-daniel-19 | custom | 2.5 | 328 | 501 | 7.6 | 0.0% |
| custom-plain-daniel-20 | custom | 2.8 | 231 | 376 | 12.1 | 0.0% |
| custom-plain-daniel-21 | custom | 2.8 | 232 | 233 | 12.1 | 0.0% |
| custom-plain-daniel-22 | custom | 2.9 | 319 | 416 | 9.1 | 0.0% |
| custom-plain-daniel-23 | custom | 2.9 | 281 | 283 | 10.4 | 0.0% |
| custom-plain-daniel-24 | custom | 2.9 | 164 | 348 | 17.6 | 0.0% |
| custom-plain-samantha-00 | custom | 2.9 | 165 | 228 | 17.4 | 0.0% |
| custom-plain-samantha-01 | custom | 2.8 | 279 | 300 | 10.2 | 0.0% |
| custom-plain-samantha-02 | custom | 3.2 | 207 | 216 | 15.7 | 0.0% |
| custom-plain-samantha-03 | custom | 3.0 | 373 | 536 | 7.9 | 0.0% |
| custom-plain-samantha-04 | custom | 3.1 | 233 | 321 | 13.5 | 0.0% |
| custom-plain-samantha-05 | custom | 3.1 | 541 | 545 | 5.7 | 0.0% |
| custom-plain-samantha-06 | custom | 2.9 | 359 | 419 | 8.1 | 0.0% |
| custom-plain-samantha-07 | custom | 3.2 | 510 | 870 | 6.3 | 0.0% |
| custom-plain-samantha-08 | custom | 2.8 | 337 | 524 | 8.2 | 0.0% |
| custom-plain-samantha-09 | custom | 2.7 | 470 | 635 | 5.7 | 0.0% |
| custom-plain-samantha-10 | custom | 3.3 | 384 | 553 | 8.5 | 0.0% |
| custom-plain-samantha-11 | custom | 3.0 | 314 | 435 | 9.6 | 11.1% |
| custom-plain-samantha-12 | custom | 3.1 | 253 | 403 | 12.1 | 0.0% |
| custom-plain-samantha-13 | custom | 2.9 | 216 | 217 | 13.3 | 0.0% |
| custom-plain-samantha-14 | custom | 2.9 | 244 | 298 | 11.9 | 20.0% |
| custom-plain-samantha-15 | custom | 2.9 | 185 | 241 | 15.4 | 0.0% |
| custom-plain-samantha-16 | custom | 2.6 | 131 | 133 | 19.6 | 0.0% |
| custom-plain-samantha-17 | custom | 3.1 | 171 | 184 | 18.2 | 0.0% |
| custom-plain-samantha-18 | custom | 3.0 | 430 | 618 | 7.1 | 0.0% |
| custom-plain-samantha-19 | custom | 2.4 | 357 | 371 | 6.7 | 0.0% |
| custom-plain-samantha-20 | custom | 2.7 | 261 | 337 | 10.3 | 0.0% |
| custom-plain-samantha-21 | custom | 2.6 | 270 | 336 | 9.7 | 0.0% |
| custom-plain-samantha-22 | custom | 2.8 | 348 | 367 | 7.9 | 0.0% |
| custom-plain-samantha-23 | custom | 2.7 | 233 | 392 | 11.8 | 0.0% |
| custom-plain-samantha-24 | custom | 2.6 | 341 | 401 | 7.5 | 0.0% |
| real-6930-75918-0000 | real | 3.5 | 258 | 315 | 13.6 | 0.0% |
| real-6930-75918-0001 | real | 14.2 | 455 | 457 | 31.3 | 0.0% |
| real-6930-75918-0002 | real | 5.0 | 149 | 168 | 33.7 | 0.0% |
| real-6930-75918-0003 | real | 23.3 | 529 | 768 | 44.1 | 0.0% |
| real-6930-75918-0004 | real | 11.1 | 285 | 294 | 38.8 | 3.2% |
| real-6930-75918-0005 | real | 13.2 | 457 | 571 | 28.8 | 0.0% |
| real-6930-75918-0006 | real | 5.8 | 255 | 259 | 22.9 | 0.0% |
| real-6930-75918-0007 | real | 3.3 | 152 | 244 | 21.9 | 0.0% |
| real-6930-75918-0008 | real | 4.8 | 237 | 245 | 20.2 | 0.0% |
| real-6930-75918-0009 | real | 7.3 | 251 | 291 | 29.0 | 0.0% |
| synthetic-01-clean | synthetic | 14.8 | 296 | 308 | 50.0 | 2.0% |
| synthetic-02-noise20 | synthetic | 14.8 | 285 | 371 | 51.9 | 0.0% |
| synthetic-03-noise10 | synthetic | 14.8 | 338 | 400 | 43.7 | 2.0% |
| synthetic-04-long | synthetic | 211.9 | 10446 | 11040 | 20.3 | 0.0% |
| synthetic-1-slack-2s | synthetic | 2.0 | 406 | 548 | 4.9 | 0.0% |
| synthetic-2-slack-5s | synthetic | 5.4 | 479 | 569 | 11.3 | 0.0% |
| synthetic-3-review-10s | synthetic | 9.6 | 448 | 552 | 21.4 | 0.0% |
| synthetic-4-email-20s | synthetic | 19.1 | 1135 | 1220 | 16.9 | 0.0% |
| synthetic-5-email-45s | synthetic | 45.5 | 3214 | 4294 | 14.1 | 0.8% |

## Transcripts

### Parakeet TDT 0.6B v3 (multilingual)

`synthetic-01-clean`

- Reference: The river meets the morning sun. Please send the revised notes before the meeting. We checked the build this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.
- Hypothesis: The river meets the morning sun, please send the revised notes before the meeting. We checked the bill this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.

`real-6930-75918-0000`

- Reference: CONCORD RETURNED TO ITS PLACE AMIDST THE TENTS
- Hypothesis: Concord returned to its place amidst the tents.

`real-6930-75918-0001`

- Reference: THE ENGLISH FORWARDED TO THE FRENCH BASKETS OF FLOWERS OF WHICH THEY HAD MADE A PLENTIFUL PROVISION TO GREET THE ARRIVAL OF THE YOUNG PRINCESS THE FRENCH IN RETURN INVITED THE ENGLISH TO A SUPPER WHICH WAS TO BE GIVEN THE NEXT DAY
- Hypothesis: the English forwarded to the French baskets of flowers, of which they had made a plentiful provision to greet the arrival of the young princess. The French, in return, invited the English to a supper, which was to be given the next day.

`custom-names-daniel-00`

- Reference: Please send the invoice to Siobhan before Friday.
- Hypothesis: Please send the invoice to Chavon before Friday.

`custom-names-daniel-01`

- Reference: Doctor Nguyen will review the Kubernetes migration plan.
- Hypothesis: Dr. Nguyen will review the Cuban Eats migration plan.

### Parakeet Ultra 0.6B (v3 post-trained)

`synthetic-01-clean`

- Reference: The river meets the morning sun. Please send the revised notes before the meeting. We checked the build this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.
- Hypothesis: The river meets the morning sun, please send the revised notes before the meeting. We checked the bill this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.

`real-6930-75918-0000`

- Reference: CONCORD RETURNED TO ITS PLACE AMIDST THE TENTS
- Hypothesis: Concord returned to its place amidst the tents.

`real-6930-75918-0001`

- Reference: THE ENGLISH FORWARDED TO THE FRENCH BASKETS OF FLOWERS OF WHICH THEY HAD MADE A PLENTIFUL PROVISION TO GREET THE ARRIVAL OF THE YOUNG PRINCESS THE FRENCH IN RETURN INVITED THE ENGLISH TO A SUPPER WHICH WAS TO BE GIVEN THE NEXT DAY
- Hypothesis: The English forwarded to the French baskets of flowers, of which they had made a plentiful provision to greet the arrival of the young princess. The French, in return, invited the English to a supper, which was to be given the next day.

`custom-names-daniel-00`

- Reference: Please send the invoice to Siobhan before Friday.
- Hypothesis: Please send the invoice to Chavon before Friday.

`custom-names-daniel-01`

- Reference: Doctor Nguyen will review the Kubernetes migration plan.
- Hypothesis: Dr. Nguyen will review the Cuba needs migration plan.

### Nemotron Unified ASR 0.6B (offline, en)

`synthetic-01-clean`

- Reference: The river meets the morning sun. Please send the revised notes before the meeting. We checked the build this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.
- Hypothesis: The river meets the morning sun. Please send the revised notes before the meeting. We checked the bill this morning and the tests are passing. Keep the old recording until the new result is safely saved. When the review is finished, copy the final sentence and close the window.

`real-6930-75918-0000`

- Reference: CONCORD RETURNED TO ITS PLACE AMIDST THE TENTS
- Hypothesis: Concord returned to its place amidst the tents,

`real-6930-75918-0001`

- Reference: THE ENGLISH FORWARDED TO THE FRENCH BASKETS OF FLOWERS OF WHICH THEY HAD MADE A PLENTIFUL PROVISION TO GREET THE ARRIVAL OF THE YOUNG PRINCESS THE FRENCH IN RETURN INVITED THE ENGLISH TO A SUPPER WHICH WAS TO BE GIVEN THE NEXT DAY
- Hypothesis: The English forwarded to the French baskets of flowers of which they had made a plentiful provision to greet the arrival of the young princess. The French, in return, invited the English to a supper, which was to be given the next day.

`custom-names-daniel-00`

- Reference: Please send the invoice to Siobhan before Friday.
- Hypothesis: Please send the invoice to Chavon before Friday.

`custom-names-daniel-01`

- Reference: Doctor Nguyen will review the Kubernetes migration plan.
- Hypothesis: Dr. Nguen will review the Cuban Eat's migration plan
