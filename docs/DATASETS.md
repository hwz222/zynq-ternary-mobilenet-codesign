# Datasets and acknowledgements

Which datasets were used, under which terms, and who supported the work.

## Acknowledgements

This work was carried out at the MIAT Laboratory, Department of Computer Science and Information
Engineering, National Central University, Taiwan, under the supervision of Dr. Ching-Han Chen.

## Datasets

No dataset is redistributed in this repository or its release: no images, videos or label files.
Obtain each dataset from its source and follow its terms.

| dataset | used for | source and terms |
|---|---|---|
| MPII Human Pose (Andriluka et al., CVPR 2014) | pose training, the validation split behind every PCKh, the test fixtures | Max Planck Institute for Informatics; annotations under the Simplified BSD licence, made available for research purposes |
| Penn Action (Zhang et al., ICCV 2013) | additional pose training data | University of Pennsylvania; see the dataset page for its terms (research use) |
| COCO 2017 and COCO-Stuff (Lin et al., ECCV 2014; Caesar et al., CVPR 2018) | detection, segmentation, people lying down | annotations under CC BY 4.0; images under their Flickr licences |
| NYU Depth V2 (Silberman et al., ECCV 2012) | depth training and evaluation | New York University; see the dataset page for its terms (research use). Used in the FastDepth h5 layout |
| UR Fall Detection Dataset (Kwolek and Kepski, 2014) | evaluation of the fall-alarm prototype | University of Rzeszow; see the dataset page for its terms |

The depth workspace also used Depth Anything V2 (metric indoor, Small) as a teacher to label COCO
images; that model is not included. The Penn Action label files used for training were made with a
tool of the earlier research code base that is not part of this repository (see
[`train/mbv2_pose/README.md`](../train/mbv2_pose/README.md)).

## License of this repository

Apache License 2.0 ([`LICENSE`](../LICENSE), [`NOTICE`](../NOTICE)). It covers the code, RTL, scripts,
documentation and the released model weights. It does not cover the datasets above.
