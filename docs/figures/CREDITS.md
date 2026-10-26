# Figure credits

## Photos in `tasks.jpg`

All five photos come from Wikimedia Commons and are released under the Creative Commons CC0 1.0
Universal Public Domain Dedication (licence checked on each file page on 2026-10-26; none carries a
personality-rights restriction). They were
downloaded at most 1,920 px wide and shown cropped and scaled; the drawings on them are ours.

| panel | file page | author | licence |
|---|---|---|---|
| yoga | [File:Woman yoga pose.jpg](https://commons.wikimedia.org/wiki/File:Woman_yoga_pose.jpg) | BodyBendYoga / Nappy.co | CC0 1.0 |
| running | [File:Lady in local costume running in Mumbai Marathon 2024.jpg](https://commons.wikimedia.org/wiki/File:Lady_in_local_costume_running_in_Mumbai_Marathon_2024.jpg) | Rudolph.A.furtado | CC0 1.0 |
| tennis | [File:Tennis Melkhuisje, halve finales Carter in actie tegen Bazazzutti, Bestanddeelnr 929-8373.jpg](https://commons.wikimedia.org/wiki/File:Tennis_Melkhuisje,_halve_finales_Carter_in_actie_tegen_Bazazzutti,_Bestanddeelnr_929-8373.jpg) | Bert Verhoeff / Anefo (Nationaal Archief) | CC0 1.0 |
| walking | [File:Woman walking down path (Unsplash).jpg](https://commons.wikimedia.org/wiki/File:Woman_walking_down_path_(Unsplash).jpg) | Biel Morro | CC0 1.0 |
| indoor (detection, segmentation, depth) | [File:Business Woman is reading Newspaper - 35870943420.jpg](https://commons.wikimedia.org/wiki/File:Business_Woman_is_reading_Newspaper_-_35870943420.jpg) | tranmautritam | CC0 1.0 |

## How `tasks.jpg` was made

- **Pose (top row).** The released detector (`det12v2_tern_probe_cont_best_bn.pth`, host model) gave
  the highest-scoring person box of each photo. A square crop of 1.25 times the box was resized to
  256 x 256, normalised and quantised to int8 exactly as the exporter quantises its fixtures, and run
  through the integer C reference `golden/ref_batch` with the release weights `model_mbv2.bin`. That
  reference is bit-exact with the board (its output on fixture 0 equals the fixture's expected output,
  which the board reproduces), so the drawn joints are the output the board produces for these
  inputs. Each joint is the arg-max of its heatmap with a quarter-cell shift toward the larger
  neighbour, mapped back to the photo.
- **Detection, segmentation, depth (bottom row).** The released host checkpoints
  `det12v2_tern_probe_cont_best_bn.pth`, `seg16_tern_probe_cont_last_bn.pth` and
  `depth_tern_probe_cont_last_bn.pth` (simulated quantisation, not the board) through the `demo`
  modules of `train/coco_det`, `train/coco_seg` and `train/nyu_depth`, on the indoor photo, because
  these models were trained on indoor scenes. Detection shows the best box per class with a score of
  at least 0.2; segmentation colours the classes listed in the panel; depth uses a fixed 0-6 m scale.

## Diagrams

`hardware.svg` (with its rendering `hardware.png`) and `architecture.svg` are original drawings made
for this repository; no vendor images are used. Board product page:
https://www.alinx.com/en/ (AXU2CGB).
