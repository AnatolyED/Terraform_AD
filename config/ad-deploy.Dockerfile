ARG GO_IMAGE=golang:1.26.6
ARG TERRAFORM_IMAGE=hashicorp/terraform:1.17.1

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
WORKDIR /src
COPY config/ad-password-bootstrap/main.go config/ad-password-bootstrap/vault.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=local \
    go build -trimpath -o /out/ad-password-bootstrap main.go vault.go

FROM ${TERRAFORM_IMAGE}
COPY --from=build /out/ad-password-bootstrap /usr/local/bin/ad-password-bootstrap
