# Reproducible WASI wheel builder pinned to wasi-sdk-27 / wasm32-wasip2 — the exact toolchain eryx
# 0.5.0 ships, so the wheels late-link into it. Full worklog + traps:
#   design_docs/code_interpreter_wasm_numpy_build.md
#
# Usage:
#   make -C tools/wasi_wheel_build numpy        # -> build/numpy-wasi.tar.gz
#   make -C tools/wasi_wheel_build prerequisites # wasi-sdk + wasm CPython + libpython3.14.so only

BUILD_DIR    := $(abspath build)
WASI_SDK     := $(BUILD_DIR)/wasi-sdk
CPYTHON_SRC  := $(BUILD_DIR)/cpython-src
CPYTHON_HOST := $(BUILD_DIR)/cpython-host
CPYTHON_WASI := $(BUILD_DIR)/cpython-wasi
CROSS_PREFIX := $(CPYTHON_WASI)/install

WASI_SDK_VERSION := 27
# dicej/cpython branch whose HEAD (342deabaab…) == eryx's bundled CPython commit.
CPYTHON_BRANCH   := v3.14.0-wasi-sdk-27
# numpy 2.0-era dev commit that still builds with setup.py (dicej's pin).
NUMPY_COMMIT     := 2ce972e4b848827023f0ee74a3a7f36228760c81

HOST_OS   := $(shell uname -s | sed -e 's/Darwin/macos/' -e 's/Linux/linux/')
HOST_ARCH := $(shell uname -m | sed -e 's/aarch64/arm64/')

.PHONY: all prerequisites numpy pillow clean
all: numpy
prerequisites: $(CROSS_PREFIX)/lib/libpython3.14.so
numpy: $(BUILD_DIR)/numpy-wasi.tar.gz

# --- wasi-sdk-27 (clang 20.1.8-wasi-sdk, same compiler eryx's CPython used) ---
$(WASI_SDK):
	@mkdir -p "$(@D)"
	cd "$(@D)" && \
	  curl -fL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$(WASI_SDK_VERSION)/wasi-sdk-$(WASI_SDK_VERSION).0-$(HOST_ARCH)-$(HOST_OS).tar.gz -o wasi-sdk.tar.gz && \
	  tar xf wasi-sdk.tar.gz && mv wasi-sdk-$(WASI_SDK_VERSION).0-$(HOST_ARCH)-$(HOST_OS) wasi-sdk && rm wasi-sdk.tar.gz

# --- CPython source (dicej fork at eryx's exact commit; clone by branch, not raw SHA — Trap #3) ---
$(CPYTHON_SRC)/configure:
	@mkdir -p "$(BUILD_DIR)"
	git clone --depth 1 --branch $(CPYTHON_BRANCH) https://github.com/dicej/cpython $(CPYTHON_SRC)

# --- native host CPython 3.14 (cross-compile needs a same-version --with-build-python; Trap #12) ---
$(CPYTHON_HOST)/python: $(CPYTHON_SRC)/configure
	@mkdir -p $(CPYTHON_HOST)
	cd $(CPYTHON_HOST) && $(CPYTHON_SRC)/configure --prefix=$(CPYTHON_HOST)/install --without-ensurepip -C && make -j$$(nproc)

# --- cross-compiled wasm CPython + hand-linked libpython3.14.so (Traps #4, #5, #15) ---
$(CROSS_PREFIX)/lib/libpython3.14.so: $(WASI_SDK) $(CPYTHON_SRC)/configure $(CPYTHON_HOST)/python
	@mkdir -p $(CPYTHON_WASI)
	cd $(CPYTHON_WASI) && \
	  WASI_SDK_PATH=$(WASI_SDK) CONFIG_SITE=$(CPYTHON_SRC)/Tools/wasm/wasi/config.site-wasm32-wasi CFLAGS=-fPIC \
	  $(CPYTHON_SRC)/Tools/wasm/wasi-env $(CPYTHON_SRC)/configure -C \
	    --host=wasm32-unknown-wasip2 --build=$$($(CPYTHON_SRC)/config.guess) \
	    --with-build-python=$(CPYTHON_HOST)/python --prefix=$(CROSS_PREFIX) \
	    --enable-wasm-dynamic-linking --disable-ipv6 --disable-test-modules && \
	  make build_all install -j$$(nproc)
	$(WASI_SDK)/bin/clang --target=wasm32-unknown-wasip2 -shared -o $(CROSS_PREFIX)/lib/libpython3.14.so \
	  -Wl,--whole-archive $(CROSS_PREFIX)/lib/libpython3.14.a -Wl,--no-whole-archive \
	  $(CPYTHON_WASI)/Modules/_hacl/libHacl_HMAC.a $(CPYTHON_WASI)/Modules/_hacl/libHacl_Hash_BLAKE2.a \
	  $(CPYTHON_WASI)/Modules/_hacl/libHacl_Hash_MD5.a $(CPYTHON_WASI)/Modules/_hacl/libHacl_Hash_SHA1.a \
	  $(CPYTHON_WASI)/Modules/_hacl/libHacl_Hash_SHA2.a $(CPYTHON_WASI)/Modules/_hacl/libHacl_Hash_SHA3.a \
	  $(CPYTHON_WASI)/Modules/_decimal/libmpdec/libmpdec.a $(CPYTHON_WASI)/Modules/expat/libexpat.a \
	  -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -ldl

# --- numpy source (init submodules or setup.py aborts — Trap #16) ---
$(BUILD_DIR)/numpy-src/setup.py:
	@mkdir -p "$(BUILD_DIR)"
	git init -q $(BUILD_DIR)/numpy-src && cd $(BUILD_DIR)/numpy-src && \
	  git remote add origin https://github.com/numpy/numpy && \
	  git fetch --depth 1 origin $(NUMPY_COMMIT) && git checkout -q FETCH_HEAD && \
	  git submodule update --init --depth 1

# --- numpy wheel (Traps #6-#11 live in numpy/build.sh) ---
$(BUILD_DIR)/numpy-wasi.tar.gz: $(CROSS_PREFIX)/lib/libpython3.14.so $(BUILD_DIR)/numpy-src/setup.py
	cd $(BUILD_DIR)/numpy-src && CROSS_PREFIX=$(CROSS_PREFIX) WASI_SDK_PATH=$(WASI_SDK) HOST_PYTHON=$(CPYTHON_HOST)/python bash $(abspath numpy/build.sh)
	@mkdir -p $(BUILD_DIR)/numpy-stage
	cp -a $(BUILD_DIR)/numpy-src/build/lib.*/numpy $(BUILD_DIR)/numpy-stage/
	cd $(BUILD_DIR)/numpy-stage && tar czf $(BUILD_DIR)/numpy-wasi.tar.gz numpy

pillow: $(BUILD_DIR)/Pillow-wasi.tar.gz

$(BUILD_DIR)/Pillow-wasi.tar.gz: $(CROSS_PREFIX)/lib/libpython3.14.so
	mkdir -p $(BUILD_DIR)/pillow
	cd $(BUILD_DIR)/pillow && CROSS_PREFIX=$(CROSS_PREFIX) WASI_SDK_PATH=$(WASI_SDK) HOST_PYTHON=$(CPYTHON_HOST)/python bash $(abspath pillow/build.sh)
	@mkdir -p $(BUILD_DIR)/pillow-stage
	cp -a $(BUILD_DIR)/pillow/Pillow-9.5.0/build/pillow-9.5.0/PIL $(BUILD_DIR)/pillow-stage/
	cd $(BUILD_DIR)/pillow-stage && tar czf $(BUILD_DIR)/Pillow-wasi.tar.gz PIL

clean:
	rm -rf $(BUILD_DIR)
