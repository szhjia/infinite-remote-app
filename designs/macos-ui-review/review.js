const scenario = document.querySelector("#scenario");
const install = document.querySelector("#install");
const choose = document.querySelector("#choose");
const installNote = document.querySelector("#install-note");
const query = document.querySelector("#query");
let installedFromLibrary = false;

const statuses = {
  unpaired: {
    icon: "!", title: "型号已添加 · 待蓝牙配对",
    description: "配对实体遥控器后，工作台会显示连接状态。现在可以查看按键布局。",
    action: "模拟配对成功",
  },
  blocked: {
    icon: "!", title: "蓝牙已连接 · 缺少输入监控",
    description: "可以浏览或编辑映射。开启输入监控后，Mac 才能读取实体键。",
    action: "查看权限",
  },
  ready: {
    icon: "✓", title: "已收到按键信号",
    description: "确认键 · 已按下并松开。可在「测试按键」中查看其他信号。",
    action: "测试按键…",
  },
  diagnosing: {
    icon: "!", title: "诊断中 · 动作暂停",
    description: "可以查看按键信号。结束诊断后，恢复此前的响应设置。",
    action: "结束诊断",
  },
};

const keyPositions = {
  "电源": [31.5, 11.5],
  "语音": [68.5, 11.5],
  "确认": [50, 26.6],
  "返回": [34.8, 41.5],
  "直播": [65, 59.6],
};

function showSettings(pane) {
  document.querySelectorAll("[data-settings]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.settings === pane));
  });
  document.querySelectorAll("[data-settings-view]").forEach((view) => {
    view.hidden = view.dataset.settingsView !== pane;
  });
}

function navigate(page, pane) {
  document.querySelectorAll("[data-view]").forEach((view) => {
    view.hidden = view.dataset.view !== page;
  });
  document.querySelectorAll(".sidebar [data-page]").forEach((button) => {
    if (button.dataset.page === page) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  if (pane) showSettings(pane);
}

function renderScenario() {
  const state = scenario.value;
  const hasModel = state !== "empty";
  document.querySelector("#setup-guide").hidden = hasModel;
  document.querySelector("#device-workbench").hidden = !hasModel;
  document.querySelector("#add-model").hidden = !hasModel;
  document.querySelector("#device-title").textContent = hasModel ? "小米蓝牙遥控器 2 Pro" : "开始使用";
  document.querySelector("#permission-state").textContent =
    ["empty", "unpaired", "blocked"].includes(state) ? "尚未授权" : "已授权";
  install.disabled = hasModel;
  install.textContent = hasModel ? "已添加" : "添加遥控器";
  choose.hidden = !hasModel;
  installNote.hidden = !installedFromLibrary;
  const status = statuses[state];
  if (!status) return;
  document.querySelector(".status-row").dataset.tone = state;
  document.querySelector("#status-icon").textContent = status.icon;
  document.querySelector("#status-title").textContent = status.title;
  document.querySelector("#status-description").textContent = status.description;
  document.querySelector("#status-action").textContent = status.action;
  document.querySelector("#diagnose").disabled = state !== "ready";
}

function filterLibrary() {
  const text = query.value.trim().toLowerCase();
  const found = "小米蓝牙遥控器 2 pro xiaomi".includes(text);
  document.querySelector("#catalog").hidden = !found;
  document.querySelector("#no-results").hidden = found;
}

document.querySelectorAll("[data-page]").forEach((button) => {
  button.addEventListener("click", () => {
    navigate(button.dataset.page, button.dataset.pane);
    if (!button.closest(".sidebar")) {
      const current = document.querySelector('.sidebar [aria-current="page"]');
      current.focus();
    }
  });
});
document.querySelectorAll("[data-settings]").forEach((button) => {
  button.addEventListener("click", () => showSettings(button.dataset.settings));
});
scenario.addEventListener("change", () => {
  installedFromLibrary = false;
  renderScenario();
  navigate("device");
});
install.addEventListener("click", () => {
  scenario.value = "unpaired";
  installedFromLibrary = true;
  renderScenario();
  installNote.querySelector("button").focus();
});
choose.addEventListener("click", () => {
  installedFromLibrary = true;
  renderScenario();
  installNote.querySelector("button").focus();
});
query.addEventListener("input", filterLibrary);
document.querySelector("#clear-search").addEventListener("click", () => {
  query.value = "";
  filterLibrary();
  query.focus();
});
document.querySelector("#status-action").addEventListener("click", () => {
  if (scenario.value === "unpaired") {
    scenario.value = "blocked";
    renderScenario();
    return;
  }
  if (scenario.value === "blocked") {
    navigate("settings", "permissions");
    document.querySelector('[data-settings="permissions"]').focus();
    return;
  }
  scenario.value = scenario.value === "ready" ? "diagnosing" : "ready";
  renderScenario();
});
document.querySelector("#diagnose").addEventListener("click", () => {
  scenario.value = "diagnosing";
  renderScenario();
  document.querySelector("#status-action").focus();
});
document.querySelectorAll("[data-key]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-key]").forEach((other) => {
      other.setAttribute("aria-pressed", String(other === button));
      other.closest("tr").classList.toggle("selected", other === button);
    });
    document.querySelector("#selection").textContent = "选中：" + button.dataset.key + " · 配置表节选";
    const [x, y] = keyPositions[button.dataset.key];
    const marker = document.querySelector("#remote-selection");
    marker.style.left = x + "%";
    marker.style.top = y + "%";
  });
});
document.querySelector("#profiles-button").addEventListener("click", () => {
  document.querySelector("#profiles").showModal();
});
renderScenario();
