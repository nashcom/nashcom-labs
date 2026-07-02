#!/bin/bash

#!/bin/bash

# Downloads, extracts and calculates SHA256 in a single pass.
# Note: Extraction happens before the SHA256 comparison.


if [ -z "$LEGO_VERSION" ]; then
  LEGO_VERSION="5.2.2"
  LEGO_AMD64_SHA256="018de6d3f2da09630caa2fbbe8c6aa459323ad0ac0a053d0e808268914b38a8b"
  LEGO_ARM64_SHA256="92c9d7d2a6377cdd4702bfaf7e0f61ea167456f1686a3899a12f289fe863c49b"
fi


GetLegoInfo()
{
  case "$(uname -m)" in
    x86_64|amd64)
      echo "amd64|$LEGO_AMD64_SHA256"
      ;;
    aarch64|arm64)
      echo "arm64|$LEGO_ARM64_SHA256"
      ;;
    *)
      echo "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}


DownloadAndProcess()
{
  local DOWNLOAD_FILE="$1"
  local PROCESS_CMD="$2"
  local EXPECTED_HASH="${3:-}"

  local HASH=$(curl -fsSL "$DOWNLOAD_FILE" | tee >(eval "$PROCESS_CMD" 2>/dev/null) | sha256sum -b | awk '{print $1}')

  if [ -z "$HASH" ]; then
    echo "Download failed: $DOWNLOAD_FILE"
    exit 1
  fi

  if [ -n "$EXPECTED_HASH" ] && [ "$HASH" != "$EXPECTED_HASH" ]; then
    echo "SHA256 mismatch for $DOWNLOAD_FILE"
    echo "Expected: $EXPECTED_HASH"
    echo "Actual:   $HASH"
    exit 1
  fi

  echo "$HASH"
}


InstallLego()
{
  IFS='|' read -r LEGO_ARCH LEGO_SHA256 <<< "$(GetLegoInfo)"

  local LEGO_URL="https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${LEGO_ARCH}.tar.gz"
  local LEGO_HASH=$(DownloadAndProcess "$LEGO_URL" "tar -xzO lego > /usr/local/bin/lego" "$LEGO_SHA256")

  chmod 755 /usr/local/bin/lego

  echo "Installed lego $(/usr/local/bin/lego --version 2>/dev/null | head -1)"
  echo "Archive SHA256: $LEGO_HASH"
}


InstallLego

echo
which lego
lego -version
echo
