/**
 * @name OmarchyDiscord
 * @author TianTomascsik
 * @description Hands your friend list and their presence to the Omarchy bar's Discord widget through a private file. Nothing leaves your machine.
 * @version 1.0.0
 * @source https://github.com/TianTomascsik/omarchy-discord
 * @website https://github.com/TianTomascsik/omarchy-discord
 */

// The widget reads this file; the path mirrors what the bar side derives from the same variables.
const fs = require("fs");
const os = require("os");
const path = require("path");

const STATE_DIR = path.join(
  (typeof process !== "undefined" && process.env.XDG_STATE_HOME) || path.join(os.homedir(), ".local", "state"),
  "omarchy-discord");
const STATE_FILE = path.join(STATE_DIR, "friends.json");
const SCHEMA = 1;
// Presence changes arrive in bursts, so one write per burst.
const DEBOUNCE_MS = 750;
// A heartbeat lets the widget tell a stopped plugin from a quiet one.
const HEARTBEAT_MS = 60000;
const REACHABLE = ["online", "idle", "dnd"];
const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

module.exports = class OmarchyDiscord {
  start() {
    this.stores = this.findStores();
    if (!this.stores) return;
    this.listener = () => this.schedule();
    this.stores.presence.addChangeListener(this.listener);
    this.stores.relationships.addChangeListener(this.listener);
    this.stores.users.addChangeListener(this.listener);
    this.lastPayload = "";
    this.write(true, true);
    this.heartbeat = setInterval(() => this.write(true, true), HEARTBEAT_MS);
  }

  stop() {
    if (this.stores) {
      this.stores.presence.removeChangeListener(this.listener);
      this.stores.relationships.removeChangeListener(this.listener);
      this.stores.users.removeChangeListener(this.listener);
    }
    clearTimeout(this.pending);
    clearInterval(this.heartbeat);
    // An inactive file tells the widget the source is gone, rather than leaving stale statuses behind.
    if (this.stores) this.write(false, true);
    this.stores = null;
  }

  // Discord renames modules between builds; the stores are fetched by their stable internal names.
  findStores() {
    const get = (name) => BdApi.Webpack.getStore(name);
    const stores = { presence: get("PresenceStore"), relationships: get("RelationshipStore"), users: get("UserStore") };
    const missing = Object.keys(stores).filter((key) => !stores[key]);
    if (missing.length === 0) return stores;
    BdApi.Logger.error("OmarchyDiscord", "Discord store not found: " + missing.join(", "));
    BdApi.UI.showToast("OmarchyDiscord: Discord changed its internals, the friend list is off", { type: "error" });
    return null;
  }

  schedule() {
    clearTimeout(this.pending);
    this.pending = setTimeout(() => this.write(true), DEBOUNCE_MS);
  }

  snapshot() {
    const { presence, relationships, users } = this.stores;
    const friends = [];
    for (const id of relationships.getFriendIDs()) {
      const user = users.getUser(id);
      const status = String(presence.getStatus(id) || "offline").toLowerCase();
      friends.push({
        id: String(id),
        name: String((user && (user.globalName || user.username)) || id),
        status: REACHABLE.includes(status) ? status : "offline"
      });
    }
    friends.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
    return friends;
  }

  // force is the heartbeat and the stop: they rewrite an unchanged list so updatedAt moves; a quiet burst does not.
  write(active, force) {
    let friends = [];
    try {
      friends = active ? this.snapshot() : [];
    } catch (error) {
      BdApi.Logger.error("OmarchyDiscord", "Could not read the friend list", error);
      return;
    }
    const payload = JSON.stringify(friends);
    if (!force && this.lastPayload === payload) return;
    this.lastPayload = payload;
    const body = JSON.stringify({ schema: SCHEMA, active: active, updatedAt: Date.now(), friends: friends });
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true, mode: DIR_MODE });
      const temporary = STATE_FILE + ".tmp";
      fs.writeFileSync(temporary, body, { mode: FILE_MODE });
      fs.renameSync(temporary, STATE_FILE);
    } catch (error) {
      BdApi.Logger.error("OmarchyDiscord", "Could not write " + STATE_FILE, error);
    }
  }
};
