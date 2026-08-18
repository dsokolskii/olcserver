const state = { rooms: [], page: "rooms", publicAccess: true, defaultCarrier: "jitsi" };
const $ = (selector) => document.querySelector(selector);

async function api(url, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body && !(options.body instanceof Blob)) headers.set("Content-Type", "application/json");
  if ((options.method || "GET") !== "GET") headers.set("X-OLC-Request", "1");
  const response = await fetch(url, { ...options, headers });
  if (response.status === 401) {
    showLogin();
    throw new Error("Требуется вход");
  }
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data.error || `Ошибка ${response.status}`);
  }
  return response;
}

function showLogin() {
  $("#login-view").classList.remove("hidden");
  $("#app-view").classList.add("hidden");
}

function showApp() {
  $("#login-view").classList.add("hidden");
  $("#app-view").classList.remove("hidden");
}

async function loadDashboard() {
  const data = await (await api("/api/dashboard")).json();
  state.rooms = data.rooms || [];
  state.publicAccess = data.publicAccess;
  state.defaultCarrier = data.defaultCarrier || "jitsi";
  $("#version-label").textContent = `Version ${data.version}`;
  $("#public-access").checked = state.publicAccess;
  $("#default-carrier").value = state.defaultCarrier;
  render();
  showApp();
}

function render() {
  $("#rooms-count").textContent = state.rooms.length;
  $("#running-count").textContent = state.rooms.filter((room) => room.status === "running").length;
  renderRooms();
}

function renderRooms() {
  const list = $("#rooms-list");
  list.replaceChildren();
  if (!state.rooms.length) {
    list.append(element("div", "empty-state", "Комнат пока нет. Создайте первую конфигурацию сервера."));
    return;
  }
  state.rooms.forEach((room) => list.append(roomCard(room)));
}

function roomCard(room) {
  const card = element("article", "room-card");
  const head = element("div", "room-head");
  const title = element("div", "room-title");
  title.append(element("h3", "", room.name), element("p", "room-description", room.description || "Без описания"));
  const more = element("div", "more-actions");
  const moreButton = element("button", "more-button", "⋯");
  moreButton.type = "button";
  moreButton.title = "Дополнительные действия";
  moreButton.setAttribute("aria-label", "Дополнительные действия");
  const menu = element("div", "action-menu");
  menu.append(action("Редактировать", () => openRoom(room)), action(room.enabled ? "Выключить" : "Включить", () => toggleRoom(room)), action("Перезапустить", () => restartRoom(room.id)), action("Удалить", () => deleteRoom(room), "delete"));
  more.append(moreButton, menu);
  moreButton.addEventListener("click", (event) => {
    event.stopPropagation();
    document.querySelectorAll(".more-actions.open").forEach((node) => { if (node !== more) node.classList.remove("open"); });
    more.classList.toggle("open");
  });
  const status = element("span", `status ${room.status}`, statusText(room.status));
  head.append(title, status, more);

  let runtimeError;
  if (room.status === "failed") {
    runtimeError = element("div", "room-runtime-error");
    runtimeError.setAttribute("role", "alert");
    runtimeError.append(
      element("strong", "", "Почему комната остановилась"),
      element("pre", "", room.error || "Процесс olcrtc завершился без сообщения об ошибке.")
    );
  }

  const meta = element("div", "room-meta");
  meta.append(metaItem("Транспорт", room.transport), metaItem("DNS", room.dns));
  if (room.transport === "vp8channel") meta.append(metaItem("FPS", String(room.vp8Fps)), metaItem("Batch", String(room.vp8Batch)));

  const link = element("div", "link-box");
  const linkInput = document.createElement("input");
  linkInput.readOnly = true;
  linkInput.value = room.link;
  const copy = element("button", "icon-button", "⧉");
  copy.title = "Копировать ссылку";
  copy.addEventListener("click", () => copyText(room.link));
  const qr = element("button", "icon-button", "▦");
  qr.title = "Показать QR-код";
  qr.setAttribute("aria-label", "Показать QR-код");
  qr.addEventListener("click", () => openQR(room));
  link.append(linkInput, copy, qr);

  card.append(head);
  if (runtimeError) card.append(runtimeError);
  card.append(meta, link);
  return card;
}

function metaItem(label, value) {
  const item = document.createElement("div");
  item.append(element("span", "", label), element("strong", "", value));
  return item;
}

function action(text, handler, className = "") {
  const button = element("button", className, text);
  button.type = "button";
  button.addEventListener("click", handler);
  return button;
}

function element(tag, className = "", text = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

function statusText(status) {
  return ({ running: "работает", failed: "ошибка", stopped: "остановлена", starting: "запуск" })[status] || status;
}

function openRoom(room = null) {
  $("#room-form").reset();
  $("#room-error").textContent = "";
  $("#room-dialog-title").textContent = room ? "Настройка комнаты" : "Новая комната";
  $("#room-id").value = room?.id || "";
  $("#room-name").value = room?.name || "";
  $("#room-description").value = room?.description || "";
  $("#room-carrier").value = room?.carrier || state.defaultCarrier;
  $("#room-transport").value = room?.transport || "datachannel";
  $("#room-external-id").value = room?.roomId || "";
  $("#room-dns").value = room?.dns || "1.1.1.1:53";
  $("#room-enabled").value = String(room?.enabled ?? true);
  $("#room-vp8-fps").value = room?.vp8Fps || 60;
  $("#room-vp8-batch").value = room?.vp8Batch || 64;
  $("#room-key").value = room?.keyHex || "";
  syncCarrier();
  $("#room-dialog").showModal();
}

function syncCarrier() {
  const transport = $("#room-carrier").value === "jitsi" ? "datachannel" : "vp8channel";
  $("#room-transport").value = transport;
  document.querySelectorAll(".vp8-field").forEach((field) => field.classList.toggle("hidden", transport !== "vp8channel"));
}

async function saveRoom(event) {
  event.preventDefault();
  const id = $("#room-id").value;
  const existing = state.rooms.find((room) => room.id === id);
  const payload = {
    id,
    name: $("#room-name").value,
    description: $("#room-description").value,
    carrier: $("#room-carrier").value,
    transport: $("#room-transport").value,
    roomId: $("#room-external-id").value,
    keyHex: $("#room-key").value,
    dns: $("#room-dns").value,
    vp8Fps: Number($("#room-vp8-fps").value),
    vp8Batch: Number($("#room-vp8-batch").value),
    enabled: $("#room-enabled").value === "true",
    createdAt: existing?.createdAt || "0001-01-01T00:00:00Z",
    updatedAt: existing?.updatedAt || "0001-01-01T00:00:00Z"
  };
  try {
    await api(id ? `/api/rooms/${id}` : "/api/rooms", { method: id ? "PUT" : "POST", body: JSON.stringify(payload) });
    $("#room-dialog").close();
    notify(id ? "Комната обновлена" : "Комната создана");
    await loadDashboard();
  } catch (error) { $("#room-error").textContent = error.message; }
}

async function deleteRoom(room) {
  if (!confirm(`Удалить комнату «${room.name}» и ее ключи?`)) return;
  try { await api(`/api/rooms/${room.id}`, { method: "DELETE" }); notify("Комната удалена"); await loadDashboard(); } catch (error) { notify(error.message, true); }
}

async function restartRoom(id) {
  try { await api(`/api/rooms/${id}/restart`, { method: "POST" }); notify("Комната перезапущена"); await loadDashboard(); } catch (error) { notify(error.message, true); }
}

async function toggleRoom(room) {
  try {
    const payload = {
      id: room.id,
      name: room.name,
      description: room.description || "",
      carrier: room.carrier,
      transport: room.transport,
      roomId: room.roomId,
      keyHex: room.keyHex,
      dns: room.dns,
      vp8Fps: room.vp8Fps,
      vp8Batch: room.vp8Batch,
      enabled: !room.enabled,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt
    };
    await api(`/api/rooms/${room.id}`, { method: "PUT", body: JSON.stringify(payload) });
    notify(room.enabled ? "Комната выключена" : "Комната включена");
    await loadDashboard();
  } catch (error) { notify(error.message, true); }
}

function openQR(room) {
  $("#qr-title").textContent = room.name;
  $("#qr-image").src = `/api/rooms/${room.id}/qr?${Date.now()}`;
  $("#qr-dialog").showModal();
}

async function exportBackup() {
  try {
    const blob = await (await api("/api/backup/export", { method: "POST" })).blob();
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `olcserver-${new Date().toISOString().slice(0, 10)}.olcbak`;
    link.click();
    URL.revokeObjectURL(link.href);
    notify("Backup создан");
  } catch (error) { notify(error.message, true); }
}

async function importBackup() {
  const file = $("#import-file").files[0];
  if (!file) return notify("Выберите файл backup", true);
  if (!confirm("Заменить все комнаты содержимым backup?")) return;
  try { await api("/api/backup/import", { method: "POST", body: file }); notify("Backup восстановлен"); await loadDashboard(); } catch (error) { notify(error.message, true); }
}

async function updateAccess() {
  const enabled = $("#public-access").checked;
  if (!enabled && !confirm("Отключить удаленный доступ? Текущая страница может перестать открываться, и понадобится SSH-туннель.")) {
    $("#public-access").checked = true;
    return;
  }
  try {
    await api("/api/settings", { method: "PUT", body: JSON.stringify({ publicAccess: enabled, defaultCarrier: state.defaultCarrier }) });
    state.publicAccess = enabled;
    notify(enabled ? "Удаленный доступ включен" : "Удаленный доступ отключен");
  } catch (error) {
    $("#public-access").checked = state.publicAccess;
    notify(error.message, true);
  }
}

async function updateDefaultCarrier() {
  const carrier = $("#default-carrier").value;
  try {
    await api("/api/settings", { method: "PUT", body: JSON.stringify({ publicAccess: state.publicAccess, defaultCarrier: carrier }) });
    state.defaultCarrier = carrier;
    notify("Провайдер по умолчанию сохранен");
  } catch (error) {
    $("#default-carrier").value = state.defaultCarrier;
    notify(error.message, true);
  }
}

async function copyText(value) {
  try { await navigator.clipboard.writeText(value); notify("Ссылка скопирована"); } catch { notify("Браузер запретил доступ к буферу обмена", true); }
}

function notify(text, error = false) {
  const message = $("#message");
  message.textContent = text;
  message.className = `message${error ? " error" : ""}`;
  clearTimeout(notify.timer);
  notify.timer = setTimeout(() => message.classList.add("hidden"), 5000);
}

function setPage(page) {
  state.page = page;
  document.querySelectorAll(".page").forEach((node) => node.classList.add("hidden"));
  $(`#${page}-page`).classList.remove("hidden");
  document.querySelectorAll(".nav-item").forEach((node) => node.classList.toggle("active", node.dataset.page === page));
  const labels = { rooms: ["Комнаты", "+ Новая комната"], settings: ["Настройки", ""] };
  $("#page-title").textContent = labels[page][0];
  $("#primary-action").textContent = labels[page][1];
  $("#primary-action").classList.toggle("hidden", !labels[page][1]);
}

$("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("#login-error").textContent = "";
  try { await api("/api/login", { method: "POST", body: JSON.stringify({ password: $("#login-password").value }) }); $("#login-password").value = ""; await loadDashboard(); } catch (error) { $("#login-error").textContent = error.message; }
});
$("#logout-button").addEventListener("click", async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); showLogin(); });
$("#room-form").addEventListener("submit", saveRoom);
$("#room-carrier").addEventListener("change", syncCarrier);
$("#room-transport").addEventListener("change", () => document.querySelectorAll(".vp8-field").forEach((field) => field.classList.toggle("hidden", $("#room-transport").value !== "vp8channel")));
$("#public-access").addEventListener("change", updateAccess);
$("#default-carrier").addEventListener("change", updateDefaultCarrier);
$("#export-button").addEventListener("click", exportBackup);
$("#import-button").addEventListener("click", importBackup);
document.querySelectorAll("[data-close]").forEach((button) => button.addEventListener("click", () => $(`#${button.dataset.close}`).close()));
document.querySelectorAll(".nav-item").forEach((button) => button.addEventListener("click", () => setPage(button.dataset.page)));
$("#primary-action").addEventListener("click", () => openRoom());
document.addEventListener("click", () => document.querySelectorAll(".more-actions.open").forEach((node) => node.classList.remove("open")));

loadDashboard().catch(() => showLogin());
