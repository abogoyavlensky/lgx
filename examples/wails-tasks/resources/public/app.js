import { Call, Events } from "/wails/runtime.js";

// One bound Go method dispatches every let-go handler by name, so there is
// no generated bindings module to import (see the wails package README).
const BRIDGE = "github.com/abogoyavlensky/letgo-packages/wails/shim.Bridge.Call";
const call = (name, ...args) => Call.ByName(BRIDGE, name, args);

const FILTERS = [
  { id: "all", label: "All" },
  { id: "active", label: "Active" },
  { id: "done", label: "Done" },
];

const matches = (filter, t) =>
  filter === "all" || (filter === "done" ? t.done : !t.done);

document.addEventListener("alpine:init", () => {
  window.Alpine.data("tasks", () => ({
    tasks: [],
    loaded: false,
    filters: FILTERS,
    filter: "all",
    draft: "",
    error: "",
    editing: null,
    editTitle: "",
    expanded: null,
    notesDraft: "",

    async init() {
      await this.reload();
      // Emitted by the backend after File > Import adds tasks.
      Events.On("tasks-changed", () => this.reload());
    },

    // Every call goes through here: a handler that throws rejects the
    // promise with its message, which becomes the banner.
    async run(name, ...args) {
      try {
        const result = await call(name, ...args);
        this.error = "";
        return result;
      } catch (e) {
        this.error = e?.message || String(e);
        return undefined;
      }
    },

    async reload() {
      const tasks = await this.run("list-tasks");
      if (tasks) this.tasks = tasks;
      this.loaded = true;
    },

    count(filter) {
      return this.tasks.filter((t) => matches(filter, t)).length;
    },

    visible() {
      return this.tasks.filter((t) => matches(this.filter, t));
    },

    openLabel() {
      const n = this.count("active");
      if (!this.loaded) return "";
      return n === 0 ? "Nothing open" : n === 1 ? "1 open" : `${n} open`;
    },

    emptyText() {
      if (this.tasks.length === 0) return "No tasks yet. Type one above and press Enter.";
      return this.filter === "done" ? "Nothing done yet." : "Nothing left to do.";
    },

    replace(task) {
      if (task) this.tasks = this.tasks.map((t) => (t.id === task.id ? task : t));
    },

    async add() {
      const title = this.draft.trim();
      if (!title) return;
      const task = await this.run("add-task", title);
      if (task) {
        this.tasks = [...this.tasks, task];
        this.draft = "";
        if (this.filter === "done") this.filter = "all";
      }
    },

    async toggle(t) {
      this.replace(await this.run("toggle-task", t.id));
    },

    startEdit(t) {
      this.editing = t.id;
      this.editTitle = t.title;
    },

    async saveEdit(t) {
      const title = this.editTitle.trim();
      this.editing = null;
      if (!title || title === t.title) return;
      this.replace(await this.run("update-task", t.id, { title }));
    },

    toggleNotes(t) {
      if (this.expanded === t.id) {
        this.expanded = null;
        return;
      }
      this.expanded = t.id;
      this.notesDraft = t.notes;
      this.$nextTick(() => this.$root.querySelector(".is-open textarea")?.focus());
    },

    async saveNotes(t) {
      if (this.notesDraft === t.notes) return;
      this.replace(await this.run("update-task", t.id, { notes: this.notesDraft }));
    },

    async remove(t) {
      if (await this.run("delete-task", t.id)) {
        this.tasks = this.tasks.filter((x) => x.id !== t.id);
        if (this.expanded === t.id) this.expanded = null;
      }
    },

    async clearDone() {
      if ((await this.run("clear-done")) !== undefined) {
        this.tasks = this.tasks.filter((t) => !t.done);
      }
    },
  }));
});
