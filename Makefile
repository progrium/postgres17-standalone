NAME			?= postgres17-standalone
VERSION 		?= v0.2
GOARGS			?=
GOOS			?= $(shell go env GOOS)
GOARCH			?= $(shell go env GOARCH)
DIST_DIR		?= dist
DIST_OS			?= darwin windows linux linux-musl
DIST_ARCH		?= arm64 amd64
LDFLAGS			:= -s -w -X main.Version=$(VERSION)

# No cgo: webframe (via glaze) binds the system web view at runtime via
# purego, so binaries cross-compile anywhere and need no C toolchain.
export CGO_ENABLED := 0

# Except linux-musl (Alpine): purego without cgo only works with glibc, so it
# is built with cgo against musl, dynamically linked so it can load WebKitGTK.
# Cross-compiled with zig.
MUSL_ARCH_arm64	:= aarch64
MUSL_ARCH_amd64	:= x86_64
musl_env = CGO_ENABLED=1 CC="zig cc -target $(MUSL_ARCH_$(1))-linux-musl -dynamic"
MUSL_LDFLAGS	:= -linkmode=external -extldflags=-dynamic

## Build binary (OS=linux-musl for the musl build)
OS				?= $(GOOS)
MUSL			= $(filter linux-musl,$(OS))
build: assets
	GOOS=$(if $(MUSL),linux,$(OS)) GOARCH=$(GOARCH) $(if $(MUSL),$(call musl_env,$(GOARCH))) \
	go build -trimpath -ldflags="$(LDFLAGS)$(if $(MUSL), $(MUSL_LDFLAGS))" $(GOARGS) .
.PHONY: build

## Build assets
assets: assets/root.tar.br assets/bzImage
.PHONY: assets

assets/root.tar.br:
	docker build --target postgres-export --output type=local,dest=./assets .

assets/bzImage:
	docker build --target kernel-export --output type=local,dest=./assets .

## Build the Alpine container image
image: assets
	docker build --build-arg VERSION=$(VERSION) -t $(NAME) .
.PHONY: image

## Clean distribution directory
clean:
	rm -rf $(DIST_DIR)
.PHONY: clean

DIST_TARGETS	:= $(foreach os, $(DIST_OS), $(foreach arch, $(DIST_ARCH), $(DIST_DIR)/$(NAME)_$(VERSION)_$(os)_$(arch).zip))

## Build distribution zips
dist: $(DIST_TARGETS)
.PHONY: dist

$(DIST_TARGETS): $(DIST_DIR)/%.zip:
	$(eval DIST_OS_ := $(word 3, $(subst _, ,$*)))
	$(eval DIST_BIN := $(DIST_DIR)/$*/$(NAME)$(if $(filter windows,$(DIST_OS_)),.exe))
	$(MAKE) build OS=$(DIST_OS_) GOARCH=$(word 4, $(subst _, ,$*)) GOARGS="$(GOARGS) -o $(DIST_BIN)"
	rm -f $@
	zip -j $@ $(DIST_BIN)
	rm -rf $(DIST_DIR)/$*

.DEFAULT_GOAL := show-help

# Inspired by <http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html>
# sed script explained:
# /^##/:
# 	* save line in hold space
# 	* purge line
# 	* Loop:
# 		* append newline + line to hold space
# 		* go to next line
# 		* if line starts with doc comment, strip comment character off and loop
# 	* remove target prerequisites
# 	* append hold space (+ newline) to line
# 	* replace newline plus comments by `---`
# 	* print line
# Separate expressions are necessary because labels cannot be delimited by
# semicolon; see <http://stackoverflow.com/a/11799865/1968>
.PHONY: show-help
show-help:
	@echo "$$(tput bold)Available rules:$$(tput sgr0)"
	@echo
	@sed -n -e "/^## / { \
		h; \
		s/.*//; \
		:doc" \
		-e "H; \
		n; \
		s/^## //; \
		t doc" \
		-e "s/:.*//; \
		G; \
		s/\\n## /---/; \
		s/\\n/ /g; \
		p; \
	}" ${MAKEFILE_LIST} \
	| LC_ALL='C' sort --ignore-case \
	| awk -F '---' \
		-v ncol=$$(tput cols) \
		-v indent=19 \
		-v col_on="$$(tput setaf 6)" \
		-v col_off="$$(tput sgr0)" \
	'{ \
		printf "%s%*s%s ", col_on, -indent, $$1, col_off; \
		n = split($$2, words, " "); \
		line_length = ncol - indent; \
		for (i = 1; i <= n; i++) { \
			line_length -= length(words[i]) + 1; \
			if (line_length <= 0) { \
				line_length = ncol - indent - length(words[i]) - 1; \
				printf "\n%*s ", -indent, " "; \
			} \
			printf "%s ", words[i]; \
		} \
		printf "\n"; \
	}' \
	| more $(shell test $(shell uname) == Darwin && echo '--no-init --raw-control-chars')