NAME			?= minipg
VERSION			?= dev
HOST_OS			:= $(shell uname -s | tr A-Z a-z | sed 's/darwin/macos/; s/^mingw.*/windows/; s/^msys.*/windows/; s/^cygwin.*/windows/')
HOST_ARCH		:= $(shell uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
OS				?= $(HOST_OS)
ARCH			?= $(HOST_ARCH)
OPTIMIZE		?= ReleaseSafe
# Windows binaries end in .exe.
exe				= $(if $(filter windows,$(1)),.exe)
OUT				?= $(NAME)$(call exe,$(OS))
# The Postgres major the binary embeds.
PG_MAJOR		?= 18
DIST_DIR		?= dist
DIST_TARGETS	?= linux_amd64 linux_arm64 macos_arm64 windows_amd64

ZIG_ARCH_amd64	:= x86_64
ZIG_ARCH_arm64	:= aarch64
# Linux builds are static musl binaries, so one runs on any distro, Alpine
# included. Windows builds need Windows 10 1803 or later (build.zig).
zig_os_linux	:= linux-musl
zig_os_macos	:= macos
zig_os_windows	:= windows
zig_target		= $(ZIG_ARCH_$(2))-$(zig_os_$(1))

## Build ./minipg for OS (linux, macos, windows) and ARCH (amd64, arm64;
## Windows is amd64 only)
build: assets/root-$(ARCH).tar.xz
	zig build -Doptimize=$(OPTIMIZE) -Dtarget=$(call zig_target,$(OS),$(ARCH)) -Dversion=$(VERSION) \
		-p .zig-out/$(OS)_$(ARCH)
	cp .zig-out/$(OS)_$(ARCH)/bin/$(NAME)$(call exe,$(OS)) $(OUT)
.PHONY: build

## Pull and trim the postgres:PG_MAJOR-alpine root for ARCH (assets/root-ARCH.tar.xz and .json)
root: assets/root-$(ARCH).tar.xz
.PHONY: root

assets/root-%.tar.xz:
	PG_MAJOR=$(PG_MAJOR) scripts/root.sh $* $@

## Run the unit tests
test: assets/root-$(ARCH).tar.xz
	zig build test -Dtarget=$(call zig_target,$(OS),$(ARCH))
.PHONY: test

## Run the end-to-end tests against ./minipg (builds it first)
e2e: build
	cd .dev/e2e && MINIPG=$(CURDIR)/$(OUT) go test -count=1 -v ./...
.PHONY: e2e

## Clean build outputs
clean:
	rm -rf $(DIST_DIR) .zig-out zig-out .zig-cache $(NAME) $(NAME).exe
.PHONY: clean

## Build distribution zips (dist/minipg_VERSION_OS_ARCH.zip)
dist: $(foreach t,$(DIST_TARGETS),$(DIST_DIR)/$(NAME)_$(VERSION)_$(t).zip)
.PHONY: dist

$(DIST_DIR)/$(NAME)_$(VERSION)_%.zip:
	mkdir -p $(DIST_DIR)/$*
	$(MAKE) build OS=$(word 1,$(subst _, ,$*)) ARCH=$(word 2,$(subst _, ,$*)) \
		OUT=$(DIST_DIR)/$*/$(NAME)$(call exe,$(word 1,$(subst _, ,$*)))
	rm -f $@
	zip -j $@ $(DIST_DIR)/$*/$(NAME)$(call exe,$(word 1,$(subst _, ,$*)))
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