"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const elements = new Map();
function element() {
  return {
    innerHTML: "",
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return element(); },
    classList: {toggle() {}},
  };
}
const viewPanels = ["overview", "demos", "addons", "access"].map((name) => ({
  dataset: {viewPanel: name}, hidden: name !== "overview",
}));
const document = {
  querySelector(selector) {
    if (!elements.has(selector)) {
      elements.set(selector, element());
    }
    return elements.get(selector);
  },
  querySelectorAll(selector) {
    return selector === "[data-view-panel]" ? viewPanels : [];
  },
  addEventListener() {},
};
const context = vm.createContext({
  document,
  window: {addEventListener() {}},
  fetch: () => new Promise(() => {}),
});
vm.runInContext(fs.readFileSync(path.join(__dirname, "../dashboard/static/app.js"), "utf8"), context);

const routes = [
  {namespace: "openshift-console", name: "console", url: "https://console-openshift-console.apps-crc.testing", admitted: true},
  {namespace: "openshift-authentication", name: "oauth-openshift", url: "https://oauth-openshift.apps-crc.testing", admitted: true},
  {namespace: "aap-operator", name: "aap", url: "https://aap.example.test", admitted: true},
  {namespace: "satellite-lab", name: "satellite", url: "https://satellite.demo.lab", admitted: true, external: true},
];
context.renderRoutes(routes);
const html = elements.get("#routes-list").innerHTML;
assert.match(html, /href="https:\/\/console-openshift-console\.apps-crc\.testing"/);
assert.match(html, /https:\/\/aap\.example\.test/);
assert.match(html, /href="https:\/\/satellite\.demo\.lab"/);
assert.doesNotMatch(html, /oauth-openshift/);
context.renderRoutes([routes[1]]);
assert.match(elements.get("#routes-list").innerHTML, /No application routes found/);
console.log("PASS: dashboard links to the console and excludes the OAuth endpoint");
context.renderRoutes([], [], [], [
  {name: "Gitea <local>", url: "https://192.168.122.55:3000"},
]);
assert.match(elements.get("#routes-list").innerHTML, /Open Gitea/);
assert.match(elements.get("#routes-list").innerHTML, /Gitea &lt;local&gt;/);
assert.doesNotMatch(elements.get("#routes-list").innerHTML, /Admitted|No application routes/);
context.renderAddons([{id: "gitea", name: "Local Gitea VM", category: "Infrastructure",
  enabled: false, state: "disabled", description: "NFS"}]);
assert.match(elements.get("#addon-grid").innerHTML, /Install \/ start VM/);
context.renderAddons([{id: "gitea", name: "Local Gitea VM", category: "Infrastructure",
  enabled: true, state: "enabled", description: "NFS"}]);
assert.match(elements.get("#addon-grid").innerHTML, /Stop VM \(retain data\)/);
const demoPayload = {
  addons: [
    {id: "lightwell", name: "Lightwell CI/CD", category: "Demo content",
      description: "Fixture", state: "enabled", enabled: true},
    {id: "product-demo-satellite", name: "Satellite Demo", category: "Demo content",
      description: "Fixture", state: "enabled", enabled: true},
  ],
  inventory: {routes},
  lightwell_services: [{name: "Gitea CI <fixture>", url: "https://git.example.test"}],
  operation: {status: "idle"},
};
context.renderDemos(demoPayload);
let demoHtml = elements.get("#demo-content").innerHTML;
assert.match(demoHtml, /href="https:\/\/git.example.test"/);
assert.match(demoHtml, /Gitea CI &lt;fixture&gt;/);
assert.match(demoHtml, /does not prove runtime health/);
assert.match(demoHtml, /Check integrations \(read-only\)/);
assert.match(demoHtml, /opens a demo PR for manual review and merge/);
assert.doesNotMatch(demoHtml, /Admitted|data-launch/);
context.selectView("demos");
assert.deepEqual(viewPanels.map((panel) => panel.hidden), [true, false, true, true]);
context.selectView("untrusted-command");
assert.deepEqual(viewPanels.map((panel) => panel.hidden), [true, false, true, true]);
context.selectView("access");
assert.deepEqual(viewPanels.map((panel) => panel.hidden), [true, true, true, false]);
demoPayload.addons[0].enabled = false;
context.renderDemos(demoPayload);
demoHtml = elements.get("#demo-content").innerHTML;
assert.match(demoHtml, /Configure demo/);
assert.match(demoHtml, /data-demo-check\s+disabled/);
demoPayload.addons = [demoPayload.addons[1]];
context.renderDemos(demoPayload);
assert.match(elements.get("#demo-content").innerHTML, /href="https:\/\/satellite\.demo\.lab"/);
assert.match(elements.get("#demo-content").innerHTML, /https:\/\/console\.redhat\.com/);
console.log("PASS: demo submenus, scoped buttons, escaping, and no implicit job launches");
