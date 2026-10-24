# The PC test bench: mitmproxy with esbuild and the polyfills, all at pinned versions.
FROM docker.io/library/node:22-bookworm-slim AS deps
WORKDIR /deps
# npm checks each package against the registry's integrity hash.
RUN npm install --no-audit --no-fund \
      esbuild@0.28.2 core-js-bundle@3.50.0 intersection-observer@0.12.2 resize-observer-polyfill@1.5.1

FROM docker.io/mitmproxy/mitmproxy:12.2.3
COPY --from=deps /deps/node_modules/@esbuild/linux-x64/bin/esbuild /usr/local/bin/esbuild
# Loaded in this order: core-js needs only ES5, the others may use what it adds.
COPY --from=deps /deps/node_modules/core-js-bundle/minified.js /opt/safarifix/polyfills/1-core-js.js
COPY --from=deps /deps/node_modules/intersection-observer/intersection-observer.js /opt/safarifix/polyfills/2-intersection-observer.js
COPY --from=deps /deps/node_modules/resize-observer-polyfill/dist/ResizeObserver.global.js /opt/safarifix/polyfills/3-resize-observer.js
COPY polyfills/ /opt/safarifix/polyfills/
COPY fix.py /opt/safarifix/fix.py
