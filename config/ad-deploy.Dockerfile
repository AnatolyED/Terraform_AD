ARG TERRAFORM_IMAGE=hashicorp/terraform:1.17.1
FROM ${TERRAFORM_IMAGE}
RUN apk add --no-cache python3
