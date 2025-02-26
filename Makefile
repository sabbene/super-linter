# Inspired by https://github.com/jessfraz/dotfiles

.PHONY: all
all: info docker test ## Run all targets.

.PHONY: test
test: info validate-container-image-labels inspec lint-codebase test-find test-linters ## Run the test suite

# if this session isn't interactive, then we don't want to allocate a
# TTY, which would fail, but if it is interactive, we do want to attach
# so that the user can send e.g. ^C through.
INTERACTIVE := $(shell [ -t 0 ] && echo 1 || echo 0)
ifeq ($(INTERACTIVE), 1)
	DOCKER_FLAGS += -t
endif

.PHONY: info
info: ## Gather information about the runtime environment
	echo "whoami: $$(whoami)"; \
	echo "pwd: $$(pwd)"; \
	echo "ls -ahl: $$(ls -ahl)"; \
	docker images; \
	docker ps

.PHONY: help
help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: inspec-check
inspec-check: ## Validate inspec profiles
	docker run $(DOCKER_FLAGS) \
		--rm \
		-v "$(CURDIR)":/workspace \
		-w="/workspace" \
		chef/inspec check \
		--chef-license=accept \
		test/inspec/super-linter

SUPER_LINTER_TEST_CONTAINER_NAME := "super-linter-test"
SUPER_LINTER_TEST_CONTAINER_URL := $(CONTAINER_IMAGE_ID)
DOCKERFILE := ''
IMAGE := $(CONTAINER_IMAGE_TARGET)

# Default to stadard
ifeq ($(IMAGE),)
IMAGE := "standard"
endif

# Default to latest
ifeq ($(SUPER_LINTER_TEST_CONTAINER_URL),)
SUPER_LINTER_TEST_CONTAINER_URL := "ghcr.io/super-linter/super-linter:latest"
endif

ifeq ($(BUILD_DATE),)
BUILD_DATE := $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
endif

ifeq ($(BUILD_REVISION),)
BUILD_REVISION := $(shell git rev-parse HEAD)
endif

ifeq ($(BUILD_VERSION),)
BUILD_VERSION := $(shell git rev-parse HEAD)
endif

GITHUB_TOKEN_PATH := "$(CURDIR)/.github-personal-access-token"

.PHONY: inspec
inspec: inspec-check ## Run InSpec tests
	DOCKER_CONTAINER_STATE="$$(docker inspect --format "{{.State.Running}}" $(SUPER_LINTER_TEST_CONTAINER_NAME) 2>/dev/null || echo "")"; \
	if [ "$$DOCKER_CONTAINER_STATE" = "true" ]; then docker kill $(SUPER_LINTER_TEST_CONTAINER_NAME); fi && \
	docker tag $(SUPER_LINTER_TEST_CONTAINER_URL) $(SUPER_LINTER_TEST_CONTAINER_NAME) && \
	SUPER_LINTER_TEST_CONTAINER_ID="$$(docker run -d --name $(SUPER_LINTER_TEST_CONTAINER_NAME) --rm -it --entrypoint /bin/ash $(SUPER_LINTER_TEST_CONTAINER_NAME) -c "while true; do sleep 1; done")" \
	&& docker run $(DOCKER_FLAGS) \
		--rm \
		-v "$(CURDIR)":/workspace \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e IMAGE=$(IMAGE) \
		-w="/workspace" \
		chef/inspec exec test/inspec/super-linter\
		--chef-license=accept \
		--diagnose \
		--log-level=debug \
		-t "docker://$${SUPER_LINTER_TEST_CONTAINER_ID}" \
	&& docker ps \
	&& docker kill $(SUPER_LINTER_TEST_CONTAINER_NAME)

.phony: docker
docker: ## Build the container image
	@if [ ! -f "${GITHUB_TOKEN_PATH}" ]; then echo "Cannot find the file to load the GitHub access token: $(GITHUB_TOKEN_PATH). Create a readable file there, and populate it with a GitHub personal access token."; exit 1; fi
	DOCKER_BUILDKIT=1 docker buildx build --load \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg BUILD_REVISION=$(BUILD_REVISION) \
		--build-arg BUILD_VERSION=$(BUILD_VERSION) \
		--secret id=GITHUB_TOKEN,src=$(GITHUB_TOKEN_PATH) \
		-t $(SUPER_LINTER_TEST_CONTAINER_URL) .

.phony: docker-pull
docker-pull: ## Pull the container image from registry
	docker pull $(SUPER_LINTER_TEST_CONTAINER_URL)

.phony: validate-container-image-labels
validate-container-image-labels: ## Validate container image labels
	$(CURDIR)/test/validate-docker-labels.sh \
		$(SUPER_LINTER_TEST_CONTAINER_URL) \
		$(BUILD_DATE) \
		$(BUILD_REVISION) \
		$(BUILD_VERSION)

.phony: test-find
test-find: ## Run super-linter on a subdirectory with USE_FIND_ALGORITHM=true
	docker run \
		-e RUN_LOCAL=true \
		-e ACTIONS_RUNNER_DEBUG=true \
		-e ERROR_ON_MISSING_EXEC_BIT=true \
		-e ENABLE_GITHUB_ACTIONS_GROUP_TITLE=true \
		-e DEFAULT_BRANCH=main \
		-e USE_FIND_ALGORITHM=true \
		-v "$(CURDIR)/.github":/tmp/lint \
		$(SUPER_LINTER_TEST_CONTAINER_URL)

.phony: lint-codebase
lint-codebase: ## Lint the entire codebase
	docker run \
		-e RUN_LOCAL=true \
		-e ACTIONS_RUNNER_DEBUG=true \
		-e DEFAULT_BRANCH=main \
		-e ENABLE_GITHUB_ACTIONS_GROUP_TITLE=true \
		-e ERROR_ON_MISSING_EXEC_BIT=true \
		-e RENOVATE_SHAREABLE_CONFIG_PRESET_FILE_NAMES="default.json,hoge.json" \
		-v "$(CURDIR):/tmp/lint" \
		$(SUPER_LINTER_TEST_CONTAINER_URL)

.phony: test-linters
test-linters: ## Run the linters test suite
	docker run \
		-e ACTIONS_RUNNER_DEBUG=true \
		-e ANSIBLE_DIRECTORY=.automation/test/ansible \
		-e DEFAULT_BRANCH=main \
		-e ENABLE_GITHUB_ACTIONS_GROUP_TITLE=true \
		-e ERROR_ON_MISSING_EXEC_BIT=true \
		-e RENOVATE_SHAREABLE_CONFIG_PRESET_FILE_NAMES="default.json,hoge.json" \
		-e RUN_LOCAL=true \
		-e TEST_CASE_RUN=true \
		-e TYPESCRIPT_STANDARD_TSCONFIG_FILE=".github/linters/tsconfig.json" \
		-v "$(CURDIR):/tmp/lint" \
		$(SUPER_LINTER_TEST_CONTAINER_URL)
