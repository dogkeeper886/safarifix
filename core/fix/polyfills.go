package fix

// vendorPolyfills, generated into polyfills_gen.go by core/go.sh, holds core-js and the IntersectionObserver
// and ResizeObserver polyfills from npm.

// performance stands in for the performance APIs Safari 10.1 lacks: shopee.tw calls PerformanceObserver and
// amazon.com calls performance.getEntriesByType. They report no entries.
const performance = `(function () {
  if (!window.PerformanceObserver) {
    var PerformanceObserver = function (callback) { this.callback = callback; };
    PerformanceObserver.prototype.observe = function () {};
    PerformanceObserver.prototype.disconnect = function () {};
    PerformanceObserver.prototype.takeRecords = function () { return []; };
    PerformanceObserver.supportedEntryTypes = [];
    window.PerformanceObserver = PerformanceObserver;
  }
  var p = window.performance;
  if (!p) return;
  ['getEntries', 'getEntriesByType', 'getEntriesByName'].forEach(function (name) {
    if (!p[name]) p[name] = function () { return []; };
  });
  ['mark', 'measure', 'clearMarks', 'clearMeasures', 'clearResourceTimings'].forEach(function (name) {
    if (!p[name]) p[name] = function () {};
  });
})();`

// toggleAttribute adds Element.toggleAttribute, which Safari 10.1 lacks: ollama.com's header calls it as the page
// scrolls, and throws a TypeError without it.
const toggleAttribute = `(function () {
  var proto = window.Element && Element.prototype;
  if (!proto || proto.toggleAttribute) return;
  Object.defineProperty(proto, 'toggleAttribute', { configurable: true, writable: true, value: function (name, force) {
    var has = this.hasAttribute(name);
    var on = force === undefined ? !has : !!force;
    if (on && !has) this.setAttribute(name, '');
    if (!on && has) this.removeAttribute(name);
    return on;
  } });
})();`

// abortController adds AbortController and AbortSignal, which Safari 10.1 lacks: Google's sign-in script calls
// them and fails with "Something went wrong" without them. Aborting can't cancel Safari's own fetch, which
// ignores the signal; it only tells the page's listeners.
const abortController = `(function () {
  if (window.AbortController) return;
  var AbortSignal = function () { this.aborted = false; this.reason = undefined; this.onabort = null; this._listeners = []; };
  AbortSignal.prototype.addEventListener = function (type, f) { if (type === 'abort') this._listeners.push(f); };
  AbortSignal.prototype.removeEventListener = function (type, f) {
    this._listeners = this._listeners.filter(function (g) { return g !== f; });
  };
  AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
  var AbortController = function () { this.signal = new AbortSignal(); };
  AbortController.prototype.abort = function (reason) {
    var s = this.signal;
    if (s.aborted) return;
    s.aborted = true;
    s.reason = reason;
    var e = { type: 'abort', target: s };
    if (s.onabort) s.onabort(e);
    s._listeners.slice().forEach(function (f) { f.call(s, e); });
  };
  window.AbortController = AbortController;
  window.AbortSignal = AbortSignal;
})();`
