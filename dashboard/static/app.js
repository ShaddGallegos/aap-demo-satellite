"use strict";

const state = {
  sessionToken: "",
  payload: null,
  activeCategory: "All",
  activeView: "overview",
  activeDemo: "lightwell",
  polling: null,
  dismissedOperationId: null,
  dismissTimer: null,
  restarting: false,
  refreshing: false,
  mail: {messages: []},
  selectedMail: null,
};

const elements = {
  alert: document.querySelector("#alert"),
  addonGrid: document.querySelector("#addon-grid"),
  categoryFilter: document.querySelector("#category-filter"),
  demoMenu: document.querySelector("#demo-menu"),
  demoContent: document.querySelector("#demo-content"),
  viewMenu: document.querySelector("#view-menu"),
  capacityGrid: document.querySelector("#capacity-grid"),
  capacityMessage: document.querySelector("#capacity-message"),
  capacityPanel: document.querySelector("#capacity-panel"),
  capacityStatus: document.querySelector("#capacity-status"),
  clusterIndicator: document.querySelector("#cluster-indicator"),
  clusterState: document.querySelector("#cluster-state"),
  clusterSummary: document.querySelector("#cluster-summary"),
  environmentOs: document.querySelector("#environment-os"),
  lastUpdated: document.querySelector("#last-updated"),
  mailContent: document.querySelector("#mail-content"),
  mailList: document.querySelector("#mail-list"),
  mailSubject: document.querySelector("#mail-subject"),
  namespaceList: document.querySelector("#namespace-list"),
  operationDetails: document.querySelector("#operation-details"),
  operationDismiss: document.querySelector("#operation-dismiss"),
  operationMessage: document.querySelector("#operation-message"),
  operationOutput: document.querySelector("#operation-output"),
  operationPanel: document.querySelector("#operation-panel"),
  operationStatus: document.querySelector("#operation-status"),
  refreshButton: document.querySelector("#refresh-button"),
  restartButton: document.querySelector("#restart-button"),
  routesList: document.querySelector("#routes-list"),
  summaryGrid: document.querySelector("#summary-grid"),
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function refreshSessionToken() {
  const response = await fetch("/api/session", {
    headers: {"Content-Type": "application/json"},
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || typeof payload.token !== "string" || !payload.token) {
    throw new Error(payload.error || "Could not refresh the dashboard session");
  }
  state.sessionToken = payload.token;
}

async function api(path, options = {}, mayRefreshSession = true) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(state.sessionToken ? {"X-AAP-Demo-Token": state.sessionToken} : {}),
      ...(options.headers || {}),
    },
  });
  const payload = await response.json().catch(() => ({}));
  // A dashboard restart rotates its memory-only token. The server rejects the
  // request before reading its body, so one retry with a fresh token cannot
  // duplicate an add-on operation or other state-changing request.
  if (response.status === 403 && payload.error === "Invalid session token" && mayRefreshSession && path !== "/api/session") {
    await refreshSessionToken();
    return api(path, options, false);
  }
  if (!response.ok) {
    throw new Error(payload.error || `Request failed with status ${response.status}`);
  }
  return payload;
}

function showAlert(message) {
  elements.alert.textContent = message;
  elements.alert.classList.remove("hidden");
}

function clearAlert() {
  elements.alert.textContent = "";
  elements.alert.classList.add("hidden");
}

function summaryCard(label, value, tone = "") {
  return `<article class="summary-card ${escapeHtml(tone)}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`;
}

function renderSummary(inventory) {
  const cluster = inventory.cluster;
  const running = cluster.state === "running";
  elements.clusterIndicator.className = `status-dot ${running ? "running" : "stopped"}`;
  elements.clusterState.textContent = running ? "Cluster running" : `Cluster ${cluster.state}`;
  elements.clusterSummary.textContent =
    `${cluster.name || "Local cluster"} · Kubernetes ${cluster.kubernetes_version} · ${inventory.host.architecture}`;
  elements.environmentOs.textContent =
    `Host OS: ${inventory.host.os || "Unknown"}` +
    (cluster.vm?.guest_os ? ` · CRC guest OS: ${cluster.vm.guest_os}` : "") +
    (inventory.host.aap_subscription ? ` · AAP subscription: ${inventory.host.aap_subscription}` : "");

  const healthyNamespaces = inventory.namespaces.filter((namespace) => namespace.ready).length;
  const readyPods = inventory.pods.filter(
    (pod) => pod.phase === "Running" && pod.ready_containers === pod.total_containers,
  ).length;
  const capacity = inventory.storage?.capacity_planning || {};
  const disk = capacity.actual_vm_disk_gib == null
    ? (cluster.vm?.disk || "Unavailable")
    : `${capacity.actual_vm_used_gib} / ${capacity.actual_vm_disk_gib} GiB`;
  const diskPercent = capacity.actual_vm_disk_gib
    ? Math.round((capacity.actual_vm_used_gib / capacity.actual_vm_disk_gib) * 100)
    : Number.parseInt(String(disk).match(/\((\d+)% used\)/)?.[1] || "0", 10);
  const diskTone = diskPercent >= 90 ? "critical" : diskPercent >= 80 ? "warning" : "";
  const fleetV2Count = (inventory.fleet_v2 || []).length;
  const fleetTotal = (inventory.fleet || []).length + fleetV2Count;
  elements.summaryGrid.innerHTML = [
    summaryCard("Namespaces ready", `${healthyNamespaces}/${inventory.namespaces.length}`),
    summaryCard("Pods ready", `${readyPods}/${inventory.pods.length}`),
    summaryCard("Active routes", inventory.routes.filter((route) => route.admitted).length),
    summaryCard("Fleet nodes", fleetTotal || "0"),
    summaryCard("Disk usage", disk, diskTone),
    summaryCard("Python v2 CLI", inventory.tool?.v2_available ? "Available" : "Not installed"),
  ].join("");
}

function formatGib(value) {
  return value == null ? "Unavailable" : `${value} GiB`;
}

function renderCapacity(inventory) {
  const capacity = inventory.storage?.capacity_planning;
  if (!capacity) {
    elements.capacityPanel.classList.add("hidden");
    return;
  }
  elements.capacityPanel.classList.remove("hidden", "warning");
  const undersized = capacity.needs_rebuild;
  const pendingConfig = capacity.configured_not_applied;
  if (undersized || pendingConfig) {
    elements.capacityPanel.classList.add("warning");
  }
  elements.capacityStatus.className = `pill ${undersized || pendingConfig ? "degraded" : "running"}`;
  elements.capacityStatus.textContent = undersized ? "Undersized" : pendingConfig ? "Config not applied" : "Planned";
  elements.capacityGrid.innerHTML = [
    summaryCard("Current VM disk", formatGib(capacity.actual_vm_disk_gib)),
    summaryCard("VM free", formatGib(capacity.actual_vm_free_gib), undersized ? "critical" : ""),
    summaryCard("Recommended", formatGib(capacity.recommended_vm_disk_gib), undersized ? "warning" : ""),
    summaryCard("Host-only estimate", formatGib(capacity.host_only_gib)),
  ].join("");
  if (undersized) {
    elements.capacityMessage.textContent =
      `This VM is below the ${capacity.recommended_vm_disk_gib} GiB planning recommendation for the enabled add-ons. ` +
      "This planning estimate is not a resize trigger. At 90% disk usage, aap-demo start adds 20% capacity after checking host space and gracefully stopping CRC; no destructive rebuild is required.";
  } else if (pendingConfig) {
    elements.capacityMessage.textContent =
      `Configured CRC disk (${capacity.configured_crc_disk_gib} GiB) does not match the existing VM. ` +
      "A supported disk-size increase takes effect on the next stopped-VM CRC start. Separately, aap-demo start checks for 90% disk usage and adds 20% capacity when needed; it never rebuilds the VM automatically.";
  } else {
    elements.capacityMessage.textContent =
      "Conservative planning estimates include safety headroom and are not exact product requirements. Host-only storage is separate from the CRC VM.";
  }
}

function renderCategories(addons) {
  const categories = ["All", ...new Set(addons.map((addon) => addon.category))];
  elements.categoryFilter.innerHTML = categories
    .map(
      (category) =>
        `<button class="filter-button ${category === state.activeCategory ? "active" : ""}" ` +
        `type="button" data-category="${escapeHtml(category)}">${escapeHtml(category)}</button>`,
    )
    .join("");
  elements.categoryFilter.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeCategory = button.dataset.category;
      renderCategories(addons);
      renderAddons(addons);
    });
  });
}

function selectView(view) {
  if (!["overview", "demos", "addons", "access", "mail"].includes(view)) {
    return;
  }
  state.activeView = view;
  document.querySelectorAll("[data-view-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.viewPanel !== view;
  });
  elements.viewMenu.querySelectorAll("button[data-view]").forEach((button) => {
    const active = button.dataset.view === view;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
}

function renderMail(mail) {
  const messages = Array.isArray(mail?.messages) ? mail.messages : [];
  if (!messages.length) {
    elements.mailList.innerHTML = '<p class="empty-state">No captured local messages yet.</p>';
    elements.mailSubject.textContent = "No message selected";
    elements.mailContent.textContent = "Run ‘aap-demo reports send’ to capture a weekly report locally.";
    return;
  }
  if (!messages.some((message) => message.id === state.selectedMail)) {
    state.selectedMail = messages[0].id;
  }
  const selected = messages.find((message) => message.id === state.selectedMail);
  elements.mailList.innerHTML = messages.map((message) => `
    <button class="mail-item ${message.id === state.selectedMail ? "active" : ""}" type="button" data-mail-id="${escapeHtml(message.id)}">
      ${escapeHtml(message.subject)}<span>${escapeHtml(message.created)}</span>
    </button>`).join("");
  elements.mailList.querySelectorAll("button[data-mail-id]").forEach((button) => {
    button.addEventListener("click", async () => {
      state.selectedMail = button.dataset.mailId;
      try {
        const message = await api(`/api/mail/${encodeURIComponent(state.selectedMail)}`);
        state.mail.messages = state.mail.messages.map((item) => item.id === message.id ? message : item);
        renderMail(state.mail);
      } catch (error) { showAlert(error.message); }
    });
  });
  elements.mailSubject.textContent = selected?.subject || "Captured message";
  elements.mailContent.textContent = selected?.text || "Select this message to load its plain-text content.";
}

function renderDemos(payload) {
  const demos = payload.addons.filter((addon) => addon.category === "Demo content");
  if (!demos.some((demo) => demo.id === state.activeDemo)) {
    state.activeDemo = demos[0]?.id;
  }
  elements.demoMenu.innerHTML = demos.map((demo) =>
    `<button class="filter-button ${demo.id === state.activeDemo ? "active" : ""}" type="button" ` +
    `data-demo="${escapeHtml(demo.id)}" aria-controls="demo-content" ` +
    `aria-pressed="${demo.id === state.activeDemo}">${escapeHtml(demo.name)}</button>`,
  ).join("");
  elements.demoMenu.querySelectorAll("button[data-demo]").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeDemo = button.dataset.demo;
      renderDemos(state.payload);
    });
  });
  const demo = demos.find((addon) => addon.id === state.activeDemo);
  if (!demo) {
    elements.demoContent.innerHTML = '<p class="empty-state">No demos are available in this checkout.</p>';
    return;
  }
  const busy = payload.operation?.status === "running";
  const routes = payload.inventory.routes;
  const links = [];
  const aap = routes.find((route) => route.namespace === "aap-operator" && route.name === "aap");
  const ao = routes.find((route) => route.namespace === "automation-orchestrator" &&
    route.name === "automation-orchestrator");
  const satellite = routes.find((route) => route.name === "satellite" && route.external);
  if (aap) {
    links.push({name: "Open AAP templates and jobs", url: aap.url});
  }
  if (demo.id === "lightwell") {
    if (ao) {
      links.push({name: "Open AO workflows and approvals", url: ao.url});
    }
    for (const service of payload.lightwell_services || []) {
      if (!links.some((link) => link.url === service.url)) {
        links.push(service);
      }
    }
  } else if (demo.id === "product-demo-satellite" && satellite) {
    links.push({name: "Open Satellite hosts and content", url: satellite.url});
    links.push({name: "Open hosted Red Hat Lightspeed", url: "https://console.redhat.com"});
  }
  const notice = demo.id === "lightwell"
    ? "Patch simulation, not a real Lightwell backport service. Requires prepared Gitea/runner/repository, OpenFlake, " +
      "and a dedicated application host. The Simulate Lightwell PR job opens a demo PR for manual review and merge. " +
      "Launch deliberately in AAP; approve production promotion only in AO. Configuration does not prove runtime health."
    : demo.id === "product-demo-satellite"
    ? "Satellite content, host registration, cloud reporting, and remote remediation are separate. " +
      "Opening a console or a configured demo does not prove current reporting or execute remediation. " +
      "Three general 2-vCPU, 4096-MiB, 15-GiB image-provisioned VMs are opt-in; local libvirt instances appear in Virt-Manager."
    : demo.id === "product-demo-infrastructure"
    ? "This imports the Infrastructure setup template only. It does not launch the template or create cloud, broker, or managed-host resources."
    : demo.id === "product-demo-eda"
    ? "This scenario requires explicit PRODUCT_DEMOS_ENABLE_EDA=true and external event-source prerequisites. It does not create Kafka, cloud resources, credentials, event sources, or rulebook activations."
    : "Select a domain and review inventory, credentials, and launch inputs in AAP. " +
      "Cloud and other external demos may need separately approved resources.";
  elements.demoContent.innerHTML = `
    <div class="panel-heading">
      <h3>${escapeHtml(demo.name)}</h3>
      <span class="pill ${escapeHtml(demo.state)}">${escapeHtml(stateLabel(demo.state))}</span>
    </div>
    <p>${escapeHtml(demo.description)}</p>
    <div class="demo-actions">
      <button class="button ${demo.enabled ? "danger" : "primary"}" type="button"
        data-demo-action="${demo.enabled ? "disable" : "enable"}"
        ${busy || demo.supported === false ? "disabled" : ""}>
        ${demo.enabled ? "Remove demo configuration" : demo.id === "product-demo-eda" ? "Enable guarded EDA demo" : "Configure demo"}
      </button>
      <button class="button secondary" type="button" data-demo-check
        ${busy || !demo.enabled || demo.supported === false ? "disabled" : ""}>
        Check integrations (read-only)
      </button>
      ${links.map((link) => `<a class="button secondary" href="${escapeHtml(link.url)}"
        target="_blank" rel="noopener noreferrer">${escapeHtml(link.name)}</a>`).join("")}
    </div>
    <p class="demo-notice">${escapeHtml(notice)}</p>
    <p class="muted">Open buttons navigate only. Run jobs and review approvals in the native application.</p>`;
  elements.demoContent.querySelector("[data-demo-action]").addEventListener("click", (event) => {
    toggleAddon(demo.id, event.currentTarget.dataset.demoAction);
  });
  elements.demoContent.querySelector("[data-demo-check]").addEventListener("click", () => {
    checkDemo(demo.id);
  });
}

function stateLabel(addonState) {
  return {
    running: "Running",
    enabled: "Configured",
    degraded: "Needs attention",
    disabled: "Disabled",
  }[addonState] || "Unknown";
}

function renderAddons(addons) {
  const operationRunning = state.payload?.operation?.status === "running";
  const filtered = addons.filter(
    (addon) => state.activeCategory === "All" || addon.category === state.activeCategory,
  );
  elements.addonGrid.innerHTML = filtered
    .map((addon) => {
      const dependencies = addon.active_dependencies?.length
        ? `Dependencies: ${addon.active_dependencies.join(", ")}`
        : "No add-on dependencies";
      const availability = addon.availability ? ` · ${addon.availability}` : "";
      const estimate = addon.capacity_estimate || {};
      const capacityText = addon.enabled
        ? `VM allowance: ${estimate.vm_gib ?? 0} GiB`
        : `Projected recommendation: ${addon.projected_vm_disk_gib ?? "?"} GiB` +
          (estimate.host_gib ? ` · Host-only: ${estimate.host_gib} GiB` : "");
      const enableLabel = addon.id === "gitea" ? "Install / start VM" : "Enable";
      const disableLabel = addon.id === "gitea" ? "Stop VM (retain data)" : "Disable";
      const button = addon.supported === false
        ? '<button class="button" type="button" disabled>Unavailable on Windows</button>'
        : addon.enabled
        ? `<button class="button danger" type="button" data-action="disable" data-addon="${addon.id}" ${operationRunning ? "disabled" : ""}>${disableLabel}</button>`
        : `<button class="button primary" type="button" data-action="enable" data-addon="${addon.id}" ${operationRunning ? "disabled" : ""}>${enableLabel}</button>`;
      return `
        <article class="addon-card">
          <div class="addon-heading">
            <h3>${escapeHtml(addon.name)}</h3>
            <span class="pill ${escapeHtml(addon.state)}">${escapeHtml(stateLabel(addon.state))}</span>
          </div>
          <p class="category">${escapeHtml(addon.category)}</p>
          <p class="description">${escapeHtml(addon.description)}</p>
          <p class="addon-meta">${escapeHtml(dependencies + availability)}</p>
          <p class="addon-capacity">${escapeHtml(addon.id === "gitea"
            ? "Outside CRC: 2 CPUs, 2 GiB RAM, 40 GiB thin OS disk + host NFS" : capacityText)}</p>
          <div class="addon-footer">
            <span class="muted">${escapeHtml(addon.short_name || addon.id)}</span>
            ${button}
          </div>
        </article>`;
    })
    .join("");
  elements.addonGrid.querySelectorAll("button[data-action]").forEach((button) => {
    button.addEventListener("click", () => toggleAddon(button.dataset.addon, button.dataset.action));
  });
}

function renderRoutes(routes, fleet = [], fleetV2 = [], externalServices = []) {
  const visibleRoutes = routes.filter(
    (route) => !(route.namespace === "openshift-authentication" && route.name === "oauth-openshift"),
  );
  if (!visibleRoutes.length && !fleet.length && !fleetV2.length && !externalServices.length) {
    elements.routesList.innerHTML = '<p class="empty-state">No application routes found.</p>';
    return;
  }
  elements.routesList.innerHTML = visibleRoutes
    .map(
      (route) => `
        <div class="route-row">
          <div>
            <a href="${escapeHtml(route.url)}" target="_blank" rel="noreferrer">${escapeHtml(route.url)}</a>
            <span class="route-name">${escapeHtml(route.namespace)} / ${escapeHtml(route.name)}</span>
          </div>
          <span class="pill ${route.admitted ? "running" : "degraded"}">${route.admitted ? "Admitted" : "Pending"}</span>
        </div>`,
    )
    .join("") + externalServices.map((service) => `
      <div class="route-row">
        <div>
          <a href="${escapeHtml(service.url)}" target="_blank" rel="noopener noreferrer">Open Gitea</a>
          <span class="route-name">${escapeHtml(service.name)}</span>
        </div>
        <span class="pill">External VM</span>
      </div>`).join("") + fleet.map((node) => `
      <div class="route-row">
        <div>
          <a href="/terminal?node=${encodeURIComponent(node.index)}" target="_blank" rel="noopener noreferrer">
            ${escapeHtml(node.hostname)} - SSH terminal
          </a>
          <span class="route-name">admin@${escapeHtml(node.ssh_host)}:${escapeHtml(node.ssh_port)}
            / guest IP ${escapeHtml(node.guest_ip || "not discovered")}</span>
          <span class="fleet-power" role="group" aria-label="Power controls for ${escapeHtml(node.hostname)}">
            <button class="power-btn" type="button" title="Start ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="start" aria-label="Start">▶</button>
            <button class="power-btn" type="button" title="Stop ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="stop" aria-label="Stop">⏹</button>
            <button class="power-btn" type="button" title="Restart ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="restart" aria-label="Restart">⟳</button>
          </span>
        </div>
        <span class="pill ${node.state === "running" ? "running" : "disabled"}">${escapeHtml(node.state)}</span>
      </div>`).join("") + fleetV2.map((node) => `
      <div class="route-row">
        <div>
          <span class="fleet-v2-name">${escapeHtml(node.name)}</span>
          <span class="route-name">Kubernetes-native fleet · ${escapeHtml(node.namespace)}
            / pod IP ${escapeHtml(node.pod_ip || "pending")}</span>
        </div>
        <span class="pill ${node.ready ? "running" : "degraded"}">${escapeHtml(node.state)}</span>
      </div>`).join("");
  elements.routesList.querySelectorAll("button[data-power]").forEach((button) => {
    button.addEventListener("click", () => fleetPower(button.dataset.node, button.dataset.power, button));
  });
}

function renderNamespaces(namespaces) {
  if (!namespaces.length) {
    elements.namespaceList.innerHTML = '<p class="empty-state">No application namespaces found.</p>';
    return;
  }
  elements.namespaceList.innerHTML = namespaces
    .map(
      (namespace) => `
        <div class="namespace-row">
          <div>
            <div class="namespace-name">${escapeHtml(namespace.name)}</div>
            <div class="namespace-count">${namespace.running_pods}/${namespace.total_pods} running</div>
          </div>
          <span class="pill ${namespace.ready ? "running" : "degraded"}">${namespace.ready ? "Ready" : "Attention"}</span>
        </div>`,
    )
    .join("");
}

function renderOperation(operation) {
  elements.restartButton.disabled = state.restarting || operation?.status === "running";
  if (
    !operation ||
    operation.status === "idle" ||
    (operation.id === state.dismissedOperationId && operation.status !== "running")
  ) {
    elements.operationPanel.className = "operation-panel hidden";
    return;
  }
  elements.operationPanel.className = "operation-panel";
  if (operation.status === "succeeded") {
    elements.operationPanel.classList.add("complete");
  } else if (operation.status === "failed") {
    elements.operationPanel.classList.add("failed");
  }
  elements.operationMessage.textContent = operation.message;
  elements.operationStatus.textContent = operation.status;
  elements.operationStatus.className =
    `pill ${operation.status === "running" ? "running-operation" : operation.status === "succeeded" ? "running" : "degraded"}`;
  elements.operationDismiss.classList.toggle("hidden", operation.status === "running");
  if (operation.output) {
    elements.operationOutput.textContent = operation.output;
    elements.operationDetails.classList.remove("hidden");
  } else {
    elements.operationOutput.textContent = "";
    elements.operationDetails.classList.add("hidden");
  }
  if (operation.status === "succeeded" && !state.dismissTimer) {
    state.dismissTimer = window.setTimeout(() => {
      state.dismissedOperationId = operation.id;
      state.dismissTimer = null;
      renderOperation(operation);
    }, 12000);
  }
}

function render(payload) {
  state.payload = payload;
  renderSummary(payload.inventory);
  renderCapacity(payload.inventory);
  renderCategories(payload.addons);
  renderAddons(payload.addons);
  renderDemos(payload);
  renderRoutes(
    payload.inventory.routes, payload.inventory.fleet || [], payload.inventory.fleet_v2 || [],
    payload.gitea_services || [],
  );
  renderNamespaces(payload.inventory.namespaces);
  renderMail(state.mail);
  renderOperation(payload.operation);
  const observation = payload.observation || {};
  const freshness = observation.fresh ? " (fresh probe)" : "";
  elements.lastUpdated.textContent = `Updated ${new Date().toLocaleTimeString()}${freshness}`;
}

async function refresh(fresh = false) {
  // Skip when a refresh is already in flight: aap-demo status --json can take
  // ~30s against a settling cluster, and overlapping fetches pile up server-side
  // and leave the UI showing an empty/stale payload (e.g. "Active routes: 0").
  if (state.restarting || state.refreshing) {
    return;
  }
  state.refreshing = true;
  elements.refreshButton.disabled = true;
  try {
    const payload = await api(fresh ? "/api/status?fresh=1" : "/api/status");
    state.mail = await api("/api/mail").catch(() => ({messages: []}));
    clearAlert();
    render(payload);
  } catch (error) {
    showAlert(error.message);
  } finally {
    state.refreshing = false;
    elements.refreshButton.disabled = false;
  }
}

async function toggleAddon(addonId, action) {
  if (state.restarting) {
    return;
  }
  if (action === "disable") {
    const confirmed = window.confirm(
      addonId === "gitea"
        ? "Stop the Gitea VM? Repositories, NFS storage and credentials will be retained. CRC is not changed."
        : `Disable ${addonId}? Workloads will be removed, but retained data and credentials will be preserved where supported.`,
    );
    if (!confirmed) {
      return;
    }
  }
  const edaDemoOptIn = addonId === "product-demo-eda" && action === "enable";
  if (edaDemoOptIn) {
    const confirmed = window.confirm(
      "Enable the guarded EDA demo after you have prepared its external event source? " +
      "This imports templates only; it will not create a broker, cloud resource, credential, event source, or rulebook activation.",
    );
    if (!confirmed) {
      return;
    }
  }
  clearAlert();
  try {
    state.dismissedOperationId = null;
    if (state.dismissTimer) {
      clearTimeout(state.dismissTimer);
      state.dismissTimer = null;
    }
    await api(`/api/addons/${encodeURIComponent(addonId)}/${action}`, {
      method: "POST",
      body: JSON.stringify({
        confirm: action === "disable",
        confirm_eda_prerequisites: edaDemoOptIn,
      }),
    });
    await refresh();
    startOperationPolling();
  } catch (error) {
    showAlert(error.message);
  }
}

async function checkDemo(demoId) {
  if (state.restarting) {
    return;
  }
  clearAlert();
  try {
    state.dismissedOperationId = null;
    if (state.dismissTimer) {
      clearTimeout(state.dismissTimer);
      state.dismissTimer = null;
    }
    await api(`/api/demos/${encodeURIComponent(demoId)}/check`, {method: "POST", body: "{}"});
    await refresh();
    startOperationPolling();
  } catch (error) {
    showAlert(error.message);
  }
}

async function fleetPower(nodeIndex, action, button) {
  if (state.restarting) {
    return;
  }
  const label = {start: "Start", stop: "Stop", restart: "Restart"}[action] || action;
  if (action !== "start") {
    const confirmed = window.confirm(`${label} fleet node ${nodeIndex}?`);
    if (!confirmed) {
      return;
    }
  }
  clearAlert();
  const buttons = elements.routesList.querySelectorAll(`button[data-node="${nodeIndex}"]`);
  buttons.forEach((btn) => { btn.disabled = true; });
  try {
    await api(`/api/fleet/${encodeURIComponent(nodeIndex)}/power`, {
      method: "POST",
      body: JSON.stringify({action}),
    });
    await refresh();
  } catch (error) {
    showAlert(error.message);
    buttons.forEach((btn) => { btn.disabled = false; });
  }
}

async function restartDashboard() {
  if (state.restarting) {
    return;
  }
  state.restarting = true;
  elements.restartButton.disabled = true;
  elements.restartButton.textContent = "Restarting...";
  elements.refreshButton.disabled = true;
  showAlert("Restarting the dashboard only. CRC and AAP will keep running.");
  try {
    const previous = await api("/api/health");
    await api("/api/restart", {method: "POST", body: "{}"});
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      await new Promise((resolve) => window.setTimeout(resolve, 500));
      try {
        const health = await api("/api/health", {signal: AbortSignal.timeout(2000)});
        if (health.instance !== previous.instance) {
          window.location.reload();
          return;
        }
      } catch {
        // The listener is briefly unavailable while the server replaces itself.
      }
    }
    throw new Error("Dashboard restart timed out. Check dashboard.log or run 'aap-demo dashboard --no-open'.");
  } catch (error) {
    showAlert(error.message);
    state.restarting = false;
    elements.restartButton.disabled = state.payload?.operation?.status === "running";
    elements.restartButton.textContent = "Restart dashboard";
    elements.refreshButton.disabled = false;
  }
}

elements.viewMenu.querySelectorAll("button[data-view]").forEach((button) => {
  button.addEventListener("click", () => selectView(button.dataset.view));
});

function startOperationPolling() {
  if (state.polling) {
    clearInterval(state.polling);
  }
  state.polling = window.setInterval(async () => {
    try {
      const operation = await api("/api/operation");
      renderOperation(operation);
      if (operation.status !== "running") {
        clearInterval(state.polling);
        state.polling = null;
        await refresh();
      }
    } catch (error) {
      showAlert(error.message);
    }
  }, 2000);
}

async function initialize() {
  try {
    const session = await api("/api/session");
    state.sessionToken = session.token;
    const preferences = await api("/api/report-preferences");
    if (!preferences.configured) {
      const captureEnabled = window.confirm(
        "Set up the local weekly-report capture mailbox? It stores sanitized reports only on this computer and never sends email externally.",
      );
      await api("/api/report-preferences", {
        method: "POST", body: JSON.stringify({capture_enabled: captureEnabled}),
      });
    }
    await refresh();
    if (state.payload?.operation?.status === "running") {
      startOperationPolling();
    }
    // Poll no faster than the slowest status collection; refresh() also
    // self-skips while one is in flight, so this only fires when idle.
    window.setInterval(() => {
      if (!state.polling) {
        refresh();
      }
    }, 45000);
  } catch (error) {
    showAlert(error.message);
  }
}

elements.refreshButton.addEventListener("click", () => refresh(true));
elements.restartButton.addEventListener("click", restartDashboard);
elements.operationDismiss.addEventListener("click", () => {
  const operation = state.payload?.operation;
  if (operation) {
    state.dismissedOperationId = operation.id;
    renderOperation(operation);
  }
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    refresh();
  }
});
window.addEventListener("focus", refresh);
initialize();
