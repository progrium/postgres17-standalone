NAME			?= postgres17-standalone
VERSION 		?= v0.1
GOARGS			?=
GOOS			?= $(shell go env GOOS)
GOARCH			?= $(shell go env GOARCH)
DIST_DIR		?= dist
DIST_OS			?= darwin windows linux
DIST_ARCH		?= arm64 amd64


## Build assets
assets: assets/root.tar.br assets/bzImage
.PHONY: assets

assets/root.tar.br:
	docker build --platform=linux/386 --target postgres -t postgres-build .
	docker rm -f postgres-export > /dev/null 2>&1 || true 
	docker create --name postgres-export postgres-build
	docker cp postgres-export:/root.tar.br ./assets/root.tar.br
	docker rm -f postgres-export

assets/bzImage:
	docker build --target=kernel -t postgres-kernel .
	docker rm -f kernel-export > /dev/null 2>&1 || true 
	docker create --name kernel-export postgres-kernel
	docker cp kernel-export:/build/arch/x86/boot/bzImage ./assets/bzImage
	docker rm -f kernel-export

DIST_ASSETS 	:= $(DIST_DIR)/postgres17-standalone
DIST_TARGETS	:= $(foreach os, $(DIST_OS), $(foreach arch, $(DIST_ARCH), $(DIST_DIR)/$(NAME)_$(VERSION)_$(os)_$(arch).zip))

## Build distribution zips
dist: $(DIST_TARGETS)
.PHONY: dist

$(DIST_TARGETS): $(DIST_DIR)/%.zip:
	$(eval DIST_GOOS := $(word 3, $(subst _, ,$*)))
	$(eval DIST_BIN := $(DIST_DIR)/$*/$(NAME)$(if $(filter windows,$(DIST_GOOS)),.exe))
	GOOS=$(DIST_GOOS) \
	GOARCH=$(word 4, $(subst _, ,$*)) \
	go build -ldflags="-X main.Version=$(VERSION)" $(GOARGS) -o $(DIST_BIN) .
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