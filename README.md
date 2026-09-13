# CITS5503 — AWS AI Demos

Teaching material for **CITS5503** (Semester 2, 2026) at the University of
Western Australia. The repository contains three hands-on demonstrations that
compare different ways of using AI and machine learning on AWS, alongside the
lecture slides.

## The three demos

1. **Amazon Rekognition** — upload images to S3 and use a task-specific AI
   service (via Lambda) to detect labels, faces, text, and celebrities, storing
   results in DynamoDB.
2. **Amazon Bedrock** — send natural-language tasks to a hosted foundation model
   through a serverless API (API Gateway → Lambda → Bedrock).
3. **Amazon SageMaker** — train an XGBoost regression model, tune its
   hyperparameters (HPO), deploy it, and evaluate its predictions.

The Jupyter notebooks are the main learning materials. **Full setup, deploy,
run, and teardown instructions are in [`demo/README.md`](demo/README.md).**

## Layout

```
.
├── CITS5503AI_2026_S2.pptx        # lecture slides
└── demo/
    ├── README.md                  # detailed instructions for all three demos
    ├── manage_demo.sh             # build / deploy / redeploy / teardown helper
    ├── images/                    # sample images used by the demos
    ├── demo1_rekognition_pipeline/  # AWS SAM app + walkthrough notebook
    ├── demo2_bedrock_api/           # AWS SAM app + walkthrough notebook
    └── demo3_sagemaker_hpo/         # SageMaker notebook + execution-role stack
```

## Getting started

Prerequisites: an AWS account, AWS CLI v2, AWS SAM CLI (Demos 1 & 2), and
Python 3.10+ with Jupyter. See [`demo/README.md`](demo/README.md) for details.

```bash
git clone <this-repo> && cd CITS5503
cp .env.example .env      # then fill in your own values (this file is git-ignored)
```

Prefer AWS IAM Identity Center / SSO short-lived credentials (`aws sso login`)
or a named CLI profile over long-lived access keys.

## ⚠️ Credentials and cost

- **Never commit AWS credentials.** `.env` is git-ignored; keep it that way.
  Do not paste keys into notebooks or slides.
- These demos use **billable** AWS services. Demo 3's real-time SageMaker
  endpoint keeps charging until deleted — always run the teardown step when you
  finish. See the "Costs and cleanup" section of [`demo/README.md`](demo/README.md).

## Local checks (no AWS calls)

```bash
cd demo
python -m unittest discover demo1_rekognition_pipeline/tests
python -m unittest discover demo2_bedrock_api/tests
python -m json.tool demo3_sagemaker_hpo/demo3_walkthrough.ipynb >/dev/null
```

## License

© 2026 Larry Huynh. Licensed under
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) —
see [`LICENSE`](LICENSE). Free to share and adapt for non-commercial purposes
with attribution, under the same terms.
