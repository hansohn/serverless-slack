MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell 'pwd')
include $(PROJECT_PATH)/Makefile.*

all: build
.PHONY: all

# This maps to the sam cli --config-env option. You can override it using
# by exporting the CONFIG_ENV variable in your shell. It defaults to: "default"
export CONFIG_ENV ?= default

ifndef CONFIG_ENV
$(error [ERROR] - CONFIG_ENV environmental variable\
 to map to the sam config-env option is not set)
endif

REPO_NAME ?= $(shell basename $(CURDIR))
TEMPLATE_FILE ?= template.yaml
SRC_DIR := src

SAM_BUILD_DIR ?= .aws-sam
$(SAM_BUILD_DIR):
	@echo '[INFO] creating build sam dir: [$(@)]'
	@mkdir -p '$(@)'

OUT_DIR ?= .out
$(OUT_DIR):
	@echo '[INFO] creating build output dir: [$(@)]'
	@mkdir -p '$(@)'

# -- gather lambda functions --
LAMBDA_FUNCTIONS_DIR := $(SRC_DIR)/lambda_functions
LAMBDA_FUNCTIONS := $(wildcard $(LAMBDA_FUNCTIONS_DIR)/*)
LAMBDA_FUNCTIONS_SRC_FILES := $(wildcard \
	$(LAMBDA_FUNCTIONS_DIR)/**/*.py \
	$(LAMBDA_FUNCTIONS_DIR)/**/**/*.py \
	$(LAMBDA_FUNCTIONS_DIR)/**/requirements.txt \
)
$(LAMBDA_FUNCTIONS): $(LAMBDA_FUNCTIONS_SRC_FILES)

# -- gather lambda layers --
LAMBDA_LAYERS_DIR := $(SRC_DIR)/lambda_layers
LAMBDA_LAYERS := $(wildcard $(LAMBDA_LAYERS_DIR)/*)
LAMBDA_LAYERS_SRC_FILES := $(wildcard \
	$(LAMBDA_LAYERS_DIR)/**/*.py \
	$(LAMBDA_LAYERS_DIR)/**/**/*.py \
	$(LAMBDA_LAYERS_DIR)/**/requirements.txt \
	$(LAMBDA_LAYERS_DIR)/**/Makefile \
)

# -- aws metadata --
AWS_DEFAULT_REGION ?= us-west-2
AWS_ACCOUNT_NAME ?= sandbox
AWS_S3_BUCKET ?= $(AWS_ACCOUNT_NAME)-lambdas-$(AWS_DEFAULT_REGION)
AWS_S3_PREFIX ?= $(subst _,-,$(REPO_NAME))\/

# -- samconfig --
SAMCONFIG_FILE ?= samconfig.toml
$(SAMCONFIG_FILE):
	@echo '[INFO] buiding samconfig template: [$(SAMCONFIG_FILE)]'
	@if [ -f templates/samconfig.toml ]; then \
		sed \
			-e 's/{AWS_REGION}/$(AWS_DEFAULT_REGION)/g' \
			-e 's/{AWS_S3_BUCKET}/$(AWS_S3_BUCKET)/g' \
			-e 's/{AWS_S3_PREFIX}/$(AWS_S3_PREFIX)/g' \
			-e 's/{STACK_NAME}/$(subst _,-,$(REPO_NAME))/g' \
			-e 's/{TEMPLATE_FILE}/$(TEMPLATE_FILE)/g' \
			templates/samconfig.toml > $(SAMCONFIG_FILE); \
	fi

# -- aws sam telemetry --
export SAM_CLI_TELEMETRY ?= 0

#-------------------------------------------------------------------------------
# python
#-------------------------------------------------------------------------------

PYTHON_VERSION ?= 3.9

# -- python venv --
VIRTUALENV_DIR ?= .venv

VENV_CFG := $(VIRTUALENV_DIR)/pyvenv.cfg
$(VENV_CFG): | $(OUT_DIR)
	@echo "[INFO] Creating python virtual env under directory: [$(VIRTUALENV_DIR)]"
	@python$(PYTHON_VERSION) -m venv '$(VIRTUALENV_DIR)'

## Configure virtual environment
python/venv: $(VENV_CFG)
.PHONY: python/venv

# -- python venv  export path --
VIRTUALENV_BIN_DIR ?= $(VIRTUALENV_DIR)/bin

# -- python install packages from requirements file --
PYTHON_REQUIREMENTS := requirements.txt

## Install pips from requirements file(s)
python/packages: $(PYTHON_REQUIREMENTS)
	@for i in $(^); do \
		echo "[INFO] Installing python dependencies file: [$$i]"; \
		source '$(VIRTUALENV_BIN_DIR)/activate' && \
			pip install -r "$$i"; \
	done
.PHONY: python/packages

## Create virtual environment and install requirements
venv: python/venv python/packages
.PHONY: venv

#-------------------------------------------------------------------------------
# sam validate
#-------------------------------------------------------------------------------

## Validate aws-sam lambda(s)
validate: $(SAMCONFIG_FILE)
	@echo '[INFO] running sam validate on config env: [$(CONFIG_ENV)]'
	-$(VIRTUALENV_BIN_DIR)/sam validate \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(^)'

.PHONY: validate

#-------------------------------------------------------------------------------
# sam build
#-------------------------------------------------------------------------------

SAM_CMD ?= $(VIRTUALENV_BIN_DIR)/sam

# -- aws-sam build --
BUILD_SOURCES := $(TEMPLATE_FILE) \
	$(LAMBDA_FUNCTIONS_SRC_FILES) \
	$(LAMBDA_LAYERS_SRC_FILES) \
	$(SAMCONFIG_FILE)

SAM_BUILD_TOML_FILE := $(SAM_BUILD_DIR)/build.toml
$(SAM_BUILD_TOML_FILE): $(BUILD_SOURCES) | $(SAM_CMD)
	@echo '[INFO] sam building config env: [$(CONFIG_ENV)]'
	'$(SAM_CMD)' build \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(SAMCONFIG_FILE)' \

## Build aws-sam lambda(s)
build: $(SAM_BUILD_TOML_FILE)
.PHONY: build

#-------------------------------------------------------------------------------
# sam local invoke
#-------------------------------------------------------------------------------

# -- aws-sam local invoke --
LOCAL_INVOKE_OUT_FILE := $(OUT_DIR)/invoke-response.txt
$(LOCAL_INVOKE_OUT_FILE): $(OUT_DIR) $(SAM_CMD)
	@echo '[INFO] sam local invoke config env: [$(CONFIG_ENV)]'
	'$(SAM_CMD)' local invoke \
		--debug \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(SAMCONFIG_FILE)' \
	| tee '$(@)'

## Local invoke aws-sam lambda(s)
local-invoke: build validate $(LOCAL_INVOKE_OUT_FILE)
.PHONY: local-invoke

#-------------------------------------------------------------------------------
# sam package
#-------------------------------------------------------------------------------

# -- aws-sam package --
PACKAGE_OUT_FILE := $(OUT_DIR)/package.yaml
$(PACKAGE_OUT_FILE): $(SAM_BUILD_TOML_FILE) | $(OUT_DIR) $(SAM_CMD)
	@echo '[INFO] sam packaging config env: [$(CONFIG_ENV)]'
	'$(SAM_CMD)' package \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(SAMCONFIG_FILE)' \
		--output-template-file '$(PACKAGE_OUT_FILE)' \
		--s3-bucket $(AWS_S3_BUCKET) \
		--s3-prefix $(AWS_S3_PREFIX) \
	| tee '$(@)'

## Package aws-sam lambda(s)
package: $(PACKAGE_OUT_FILE)
.PHONY: package

#-------------------------------------------------------------------------------
# sam publish
#-------------------------------------------------------------------------------

# -- aws-sam publish --
PUBLISH_OUT_FILE := $(OUT_DIR)/publish.txt
$(PUBLISH_OUT_FILE): $(PACKAGE_OUT_FILE) | $(OUT_DIR) $(SAM_CMD)
	@echo '[INFO] sam publishing config env: [$(CONFIG_ENV)]'
	'$(SAM_CMD)' publish \
		--debug \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(SAMCONFIG_FILE)' \
		--template '$(PACKAGE_OUT_FILE)' \
	| tee '$(@)'

## Publish aws-sam lambda(s)
publish: $(PUBLISH_OUT_FILE)
.PHONY: publish

#-------------------------------------------------------------------------------
# sam deploy
#-------------------------------------------------------------------------------

# -- aws-sam deploy --
DEPLOY_OUT_FILE := $(OUT_DIR)/deploy.txt
$(DEPLOY_OUT_FILE): $(SAM_BUILD_TOML_FILE) | $(OUT_DIR) $(SAM_CMD)
	@rm -f '$(DELETE_STACK_OUT_FILE)'
	@echo '[INFO] sam deploying config env: [$(CONFIG_ENV)]'
	'$(SAM_CMD)' deploy \
		--config-env '$(CONFIG_ENV)' \
		--config-file '$(SAMCONFIG_FILE)' \
	| tee '$(@)'

## Deploy aws-sam lambda(s)
deploy: $(DEPLOY_OUT_FILE)
.PHONY: deploy

#-------------------------------------------------------------------------------
# delete stack
#-------------------------------------------------------------------------------

# -- delete cloudformation stack --
DELETE_STACK_OUT_FILE := $(OUT_DIR)/cfn-delete.txt
$(DELETE_STACK_OUT_FILE): $(SAMCONFIG_FILE) | $(OUT_DIR)
	@STACK_NAME=$$(python -c 'import toml; print( \
		toml.load("$(SAMCONFIG_FILE)")["$(CONFIG_ENV)"]["deploy"]["parameters"]["stack_name"] \
		)' \
	) ; \
	read -p "Do you want to delete the cloudformation stack: [$${STACK_NAME}]? " -r REPLY \
		&& [[ "$$REPLY" =~ ^[Yy]$$ ]] \
	&& echo "[INFO] deleting stack name: [$${STACK_NAME}]" \
	&& rm -f '$(DEPLOY_OUT_FILE)' \
	&& aws cloudformation delete-stack --stack-name "$${STACK_NAME}" \
	| tee '$(@)'

## Delete cloudformation stack
delete/cfn-stack: $(DELETE_STACK_OUT_FILE)
.PHONY: delete/cfn-stack

#-------------------------------------------------------------------------------
# tests
#-------------------------------------------------------------------------------

EVENTS_DIR := events

# build dynamic targets for sam local invoke
# each lambda function should have a corresponding invoke-local-% target
SAM_INVOKE_TARGETS := $(patsubst \
	$(LAMBDA_FUNCTIONS_DIR)/%, \
	local-invoke-%, \
	$(LAMBDA_FUNCTIONS) \
)
.PHONY: $(SAM_INVOKE_TARGETS)
$(SAM_INVOKE_TARGETS): build

ifdef DEBUGGER
DEBUG_PORT ?= 5678
export LOCAL_INVOKE_DEBUG_ARGS ?= --debug-port $(DEBUG_PORT) \
	--debug-args '-m debugpy --listen 0.0.0.0:$(DEBUG_PORT) --wait-for-client'
else
export LOCAL_INVOKE_DEBUG_ARGS ?= \

endif

# Invoke the default event associated with the lambda function
# for each lambda function, there should be a corresponding
# <CONFIG_ENV>.json file under the events/<lambda_function_dir> directory
# where <lambda_function_dir> matches the directory name under
# src/lambda_functions. For example:
#
# make local-invoke-<lambda_function_dir>
#
# You may override the event file by setting the EVENT_FILE environmental
# variable:
# EVENT_FILE=myevent.json make local-invoke-<lambda_function_dir>
#
# The Lambda functions are invoked using environment variables from the file
# under events/<lambda_function_dir>/<CONFIG_ENV>-env-vars.json. This passes the --env-vars
# parameter to `sam local invoke`. See:
# https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-using-invoke.html#serverless-sam-cli-using-invoke-environment-file
# You can override the file by setting the ENV_VARS_FILE environmental variable:
#
# EVENT_VARS_FILE=my-env-vars.json make local-invoke-<lambda_function_dir>
#
# It parses out the logical resource name from the build.toml file
# For example, to invoke the src/lambda_functions/incoming_process use:
# make local-invoke-incoming_process
#
# To debug inside a Lambda function put debugpy in the function requirements.txt
# under the function directory. Set the DEBUGGER environmental variable when
# calling local invoke VS Code setup a launch task to attach to the debugger:
#        {
#            "name": "Debug SAM Lambda debugpy attach",
#            "type": "python",
#            "request": "attach",
#            "port": 5678,
#            "host": "localhost",
#            "pathMappings": [
#                {
#                    "localRoot": "${workspaceFolder}/${relativeFileDirname}",
#                    "remoteRoot": "/var/task"
#                }
#            ],
#        }
#
# To debug the incoming_process function use:
# DEBUGGER=true make local-invoke-incoming_process
$(SAM_INVOKE_TARGETS): local-invoke-%: $(LAMBDA_FUNCTIONS_DIR)/% | $(OUT_DIR) $(SAM_CMD)
	@FUNCTION_LOGICAL_ID=$$( \
	'$(VIRTUALENV_BIN_DIR)/python' -c 'import toml; \
	f_defs = ( \
	    toml.load("$(SAM_BUILD_TOML_FILE)") \
	    .get("function_build_definitions") \
	); \
	print( \
	    [f_defs[f]["functions"][0] \
	    for f in f_defs \
	    if f_defs[f]["codeuri"].endswith("/$(*)")] \
	    [0] \
	);' \
	) || { \
		echo -n "[ERROR] failed to parse sam build toml file. "; >&2 \
		echo -n "Check that you have sourced the python virtual env and "; >&2 \
		echo -n "run the command: "; >&2 \
		echo "[pip install -r $(PYTHON_REQUIREMENTS)]"; >&2 \
		exit 1; \
	} && \
	EVENT_FILE="$${EVENT_FILE:-$(EVENTS_DIR)/$(*)/$(CONFIG_ENV).json}" && \
	ENV_VARS_FILE="$${ENV_VARS_FILE:-$(EVENTS_DIR)/$(*)/$(CONFIG_ENV)-env-vars.json}" && \
	echo "[INFO] invoking target: [$(@)] function: [$${FUNCTION_LOGICAL_ID}] with event file: [$${EVENT_FILE}]" && \
	'$(SAM_CMD)' local invoke \
		--config-env '$(CONFIG_ENV)' \
		--event "$$EVENT_FILE" \
		--env-vars "$$ENV_VARS_FILE" \
		$(LOCAL_INVOKE_DEBUG_ARGS) \
		"$$FUNCTION_LOGICAL_ID" | \
		tee '$(OUT_DIR)/$(@).txt'
	@tail '$(OUT_DIR)/$(@).txt' | grep -q -E '^{ *"errorMessage" *:.*"errorType" *:' && { \
		echo "[ERROR] Lambda local invoke returned an error" >&2;\
		exit 1; \
	} || true

test-local-invoke-default: $(SAM_INVOKE_TARGETS)
.PHONY: test-local-invoke-default

test: test-local-invoke-default
.PHONY: test

#-------------------------------------------------------------------------------
# lint
#-------------------------------------------------------------------------------

# -- cfn-lint --
## Cloudformation template linter
lint/cfn-lint: $(TEMPLATE_FILE)
	@echo '[INFO] running cfn-lint on template: [$(^)]'
	-@$(VIRTUALENV_BIN_DIR)/cfn-lint '$(^)'
.PHONY: lint/cfn-lint

# -- yamllint --
## YAML template linter
lint/yamllint: $(TEMPLATE_FILE)
	@echo '[INFO] running yamllint on template: [$(^)]'
	-@$(VIRTUALENV_BIN_DIR)/yamllint '$(^)'
.PHONY: lint/yamllint

# -- all configuration linters --ak
## Run all 'configuration file' linters, validators, and security analyzers
lint/all-cfg: lint/cfn-lint lint/yamllint validate
.PHONY: lint/all-cfg

# -- pylint --
PYLINT_DISABLE_IDS ?= W0511
PYTHON_LINTER_MAX_LINE_LENGTH ?= 100
## Python linter
lint/pylint: $(LAMBDA_FUNCTIONS)
	-@for i in $(^); do \
		echo "[INFO] running pylint on dir: [$$i]"; \
		$(VIRTUALENV_BIN_DIR)/pylint \
			--max-line-length="$(PYTHON_LINTER_MAX_LINE_LENGTH)" \
			--disable="$(PYLINT_DISABLE_IDS)" \
			"$$i"; \
	done
.PHONY: lint/pylint

# -- flake8 --
## Python styleguide enforcement
lint/flake8: $(LAMBDA_FUNCTIONS)
	-@for i in $(^); do \
		echo "[INFO] running flake8 on dir: [$$i]"; \
		$(VIRTUALENV_BIN_DIR)/flake8 \
			--max-line-length="$(PYTHON_LINTER_MAX_LINE_LENGTH)" \
			"$$i"; \
	done
.PHONY: lint/flake8

# -- mypy --
## Python static typing
lint/mypy: $(LAMBDA_FUNCTIONS)
	-@for i in $(^); do \
		echo "[INFO] running mypy on dir: [$$i]"; \
		$(VIRTUALENV_BIN_DIR)/mypy \
			"$$i"; \
	done
.PHONY: lint/mypy

# -- black --
## Python code formatter
lint/black: $(LAMBDA_FUNCTIONS)
	-@for i in $(^); do \
		echo "[INFO] running black on dir: [$$i]"; \
		$(VIRTUALENV_BIN_DIR)/black \
			--check \
			--diff \
			--line-length="$(PYTHON_LINTER_MAX_LINE_LENGTH)" \
			"$$i"; \
	done
.PHONY: lint/black

# -- bandit --
## Python security linter
lint/bandit: $(LAMBDA_FUNCTIONS)
	-@for i in $(^); do \
		echo "[INFO] running bandit on dir: [$$i]"; \
		$(VIRTUALENV_BIN_DIR)/bandit \
			--recursive \
			"$$i"; \
	done
.PHONY: lint/bandit

## Run all 'python' linters, validators, and security analyzers
lint/all-python: lint/pylint lint/flake8 lint/mypy lint/black lint/bandit
.PHONY: lint/all-python

## Run all linters, validators, and security analyzers
lint: lint/all-cfg lint/all-python
.PHONY: lint

#-------------------------------------------------------------------------------
# clean
#-------------------------------------------------------------------------------

## Clean output directory
clean/out-dir:
	@[ -d '$(OUT_DIR)' ] && rm -rf '$(OUT_DIR)/'*
.PHONY: clean/out-dir

## Clean virtual environment directory
clean/venv:
	@[ -d '$(VIRTUALENV_DIR)' ] && rm -rf '$(VIRTUALENV_DIR)/'*
.PHONY: clean/venv

## Clean
clean: clean/out-dir # clean/venv
.PHONY: clean
