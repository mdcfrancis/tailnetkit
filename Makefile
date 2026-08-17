# TailnetKit — builds the embedded-Tailscale binary dependency.
#
# TailscaleKit.xcframework is a build artifact, not a checked-in file: the
# three slices total ~100MB. Run `make bootstrap` once after cloning, and
# again whenever Vendor/libtailscale changes.

# xcode-select often points at CommandLineTools, which cannot run xcodebuild.
# Override on the command line if Xcode lives elsewhere.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
# The vendor c-archive targets shell out to `go`, which is not on a default
# GUI-inherited PATH. Harmless when Go is installed elsewhere.
export PATH := $(PATH):/usr/local/go/bin

VENDOR   := Vendor/libtailscale/swift
PRODUCTS := $(VENDOR)/build/Build/Products
OUT      := binary/TailscaleKit.xcframework

.PHONY: help
help:  ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: $(OUT)  ## Build TailscaleKit.xcframework (macOS + iOS + iOS Simulator)

$(OUT):
	$(MAKE) -C $(VENDOR) macos
	$(MAKE) -C $(VENDOR) ios
	$(MAKE) -C $(VENDOR) ios-sim
	@mkdir -p binary
	# -create-xcframework refuses to overwrite an existing output.
	rm -rf $(OUT)
	xcodebuild -create-xcframework \
	  -framework $(PRODUCTS)/Release/TailscaleKit.framework \
	  -framework $(PRODUCTS)/Release-iphoneos/TailscaleKit.framework \
	  -framework $(PRODUCTS)/Release-iphonesimulator/TailscaleKit.framework \
	  -output $(OUT)

.PHONY: slices
slices:  ## List the slices in the built xcframework
	@plutil -extract AvailableLibraries raw -o - $(OUT)/Info.plist >/dev/null \
	  && plutil -p $(OUT)/Info.plist | grep LibraryIdentifier

.PHONY: test
test: bootstrap  ## Run the package tests
	swift test

.PHONY: clean
clean:  ## Remove the xcframework and the vendor build directory
	rm -rf $(OUT) $(VENDOR)/build .build

.PHONY: distclean
distclean: clean  ## Also remove the Go c-archives (forces a full Go rebuild)
	$(MAKE) -C Vendor/libtailscale clean
