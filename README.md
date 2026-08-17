# hermes-docker

This compose setup builds a custom `hermes-agent` image from the local `Dockerfile` rather than using a published image directly.

## Why this custom image exists

The local Dockerfile is used to install additional dependencies and package extensions required by your Hermes deployment.

This custom image:

- builds from the upstream `nousresearch/hermes-agent` base image
- installs browser, PowerPoint, and document-processing libraries

Use this custom image when your Hermes setup requires the extra packages and runtime configuration that are not included in the upstream base image.
