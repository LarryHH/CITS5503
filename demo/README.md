# CITS5503 AWS AI demos

These three practical demonstrations compare different ways of using AI and
machine learning on AWS:

1. **Amazon Rekognition:** upload images and use an existing, task-specific AI
   service to identify labels, faces, text, and celebrities.
2. **Amazon Bedrock:** send different natural-language tasks to a hosted
   foundation model through a serverless web API.
3. **Amazon SageMaker:** train an XGBoost regression model, tune its
   hyperparameters, deploy it, and evaluate its predictions.

The notebooks are the main learning materials. They explain the architecture,
run each workflow, and help you interpret the results. The AWS Console is useful
for seeing the resources created behind each notebook.

All examples use `ap-southeast-2` (Sydney) unless you explicitly provide a
different region.

## What you need

- An AWS account with permission to create the services used by the demos.
- AWS CLI v2 configured with short-lived credentials, preferably through IAM
  Identity Center/SSO.
- AWS SAM CLI for Demos 1 and 2.
- Python 3.10 or later and Jupyter for the notebooks.

Check your AWS identity before deploying anything:

```bash
aws sts get-caller-identity
aws configure get region
```

If you use a named AWS CLI profile, add `--profile YOUR_PROFILE` to each
`manage_demo.sh` command. Never place AWS access keys in this repository, a
notebook, or a `.env` file committed to version control.

AWS SAM installation instructions are available in the
[AWS SAM documentation](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html).

## Managing the demos

Run the management script from this directory:

```bash
cd demo
```

The common workflow is:

```text
build → deploy → run the notebook → teardown
```

- `build` prepares or validates the local demo.
- `deploy` creates its AWS resources.
- `redeploy` rebuilds and updates an existing deployment.
- `teardown` deletes its AWS resources and requires `--yes`.

For Demos 1 and 2, `build` runs `sam build`. Demo 3 is not a SAM application;
its `build` action checks that the notebook is valid JSON.

## Demo 1: serverless image analysis

The first demo connects S3, Lambda, Rekognition, DynamoDB, and CloudWatch. An
image uploaded under the `uploads/` prefix triggers the workflow automatically.

### Build and deploy

```bash
./manage_demo.sh --demo 1 --action build
./manage_demo.sh --demo 1 --action deploy
```

On the first deployment, SAM may ask you to confirm its settings and permission
to create IAM roles.

### Run

Open and run
[`demo1_rekognition_pipeline/demo1_walkthrough.ipynb`](demo1_rekognition_pipeline/demo1_walkthrough.ipynb).

The notebook will:

- read the generated bucket, table, and function names from CloudFormation;
- upload the supplied images to S3;
- inspect the results saved in DynamoDB;
- draw Rekognition results over the source images; and
- retrieve the relevant Lambda logs from CloudWatch.

### Clean up

```bash
./manage_demo.sh --demo 1 --action teardown --yes
```

The script empties the generated demo bucket before deleting the SAM stack.
Check the demo number carefully whenever you use `--yes`.

## Demo 2: serverless foundation-model API

The second demo connects API Gateway, Lambda, Amazon Bedrock, and CloudWatch.
The same web API can perform different language tasks because each request
contains a different prompt.

### Build and deploy

```bash
./manage_demo.sh --demo 2 --action build
./manage_demo.sh --demo 2 --action deploy
```

### Run

Open and run
[`demo2_bedrock_api/demo2_walkthrough.ipynb`](demo2_bedrock_api/demo2_walkthrough.ipynb).

The notebook will:

- read the API URL from the CloudFormation stack;
- send prompts through API Gateway and Lambda;
- inspect the model response and token usage; and
- retrieve evidence of the Bedrock invocation from CloudWatch.

The API is intentionally public for this short exercise. Its throttle and
Lambda concurrency are limited, but it should still be deleted after use.

### Clean up

```bash
./manage_demo.sh --demo 2 --action teardown --yes
```

## Demo 3: SageMaker training and hyperparameter tuning

The third demo uses SageMaker managed XGBoost to train an untuned model and four
hyperparameter-optimisation (HPO) trials. It then deploys the selected model and
compares three approaches on held-out test data:

- predicting the training-set mean for every patient;
- untuned XGBoost; and
- the selected HPO model.

### Validate and deploy the prerequisites

Demo 3 needs a globally unique S3 bucket name:

```bash
./manage_demo.sh --demo 3 --action build
./manage_demo.sh --demo 3 --action deploy \
  --bucket YOUR-GLOBALLY-UNIQUE-BUCKET
```

The deploy command creates the bucket if necessary and deploys the SageMaker
execution-role stack. You do not need to copy the bucket name or role ARN into
the notebook; it reads both from the stack.

### Run

Open and run
[`demo3_sagemaker_hpo/demo3_walkthrough.ipynb`](demo3_sagemaker_hpo/demo3_walkthrough.ipynb).

Run the cells in order. In particular:

1. Allow the dependency-installation cell to finish, restarting the kernel if
   Jupyter asks you to.
2. Wait for the untuned baseline training job.
3. Start the asynchronous tuning job only once.
4. Rerun the status and job-comparison cells while the four trials run.
5. Continue to deployment only after the tuning status is `Completed`.
6. Inspect the mean-only, untuned-XGBoost, and HPO prediction diagnostics.

The notebook saves its resource names in the untracked
`demo3_sagemaker_hpo/.demo-state.json` file. This allows later cells and the
cleanup script to find the same resources after a kernel restart.

The real-time SageMaker endpoint incurs charges while it is deployed, even if
you are not sending requests. Run the cleanup command when you finish.

### Clean up

Delete the endpoint, endpoint configuration, model, role stack, and local state
file:

```bash
./manage_demo.sh --demo 3 --action teardown --yes
```

The training and HPO job history remains visible in SageMaker, but its compute
instances stop when the jobs finish.

To also delete the demo's S3 data, model artefacts, and bucket, provide the same
bucket name used for deployment:

```bash
./manage_demo.sh --demo 3 --action teardown --yes \
  --delete-s3 \
  --bucket YOUR-GLOBALLY-UNIQUE-BUCKET
```

## Costs and cleanup

These demos use billable AWS services. Demo 3's real-time endpoint is the most
important resource to remove promptly because it continues running until it is
deleted. Use the Billing and Cost Management console to inspect account costs;
recent usage can take roughly a day to appear.

Before finishing, check that no demo resources remain:

- CloudFormation stacks: `cits5503-demo1`, `cits5503-demo2`, and
  `cits5503-demo3-role`;
- SageMaker endpoints beginning with `cits5503-diabetes-`; and
- the Demo 3 bucket, if you intended to delete it.

## Local checks

These checks do not call AWS:

```bash
python -m unittest discover demo1_rekognition_pipeline/tests
python -m unittest discover demo2_bedrock_api/tests
python -m json.tool demo3_sagemaker_hpo/demo3_walkthrough.ipynb >/dev/null
```
