// Stand-ins for the performance APIs Safari 10.1 lacks: shopee.tw calls PerformanceObserver,
// amazon.com calls performance.getEntriesByType. They report no entries.
(function () {
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
})();
