// Wiretap UI — hand-rolled on purpose: no bundler (discovery B8).
// phoenix.min.js / phoenix_live_view.min.js are served from the installed deps.

window.wiretapToggleTheme = () => {
  const root = document.documentElement;
  const current =
    root.dataset.theme ||
    (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const next = current === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  localStorage.setItem("wiretap:theme", next);
};

const Hooks = {
  // Follow-mode (discovery B3): stick to the bottom like `journalctl -f`;
  // scrolling up pauses, the pill resumes. Entirely client-side.
  WiretapFollow: {
    mounted() {
      this.follow = true;
      this.pill = document.getElementById("follow-pill");
      this.el.addEventListener("scroll", () => {
        const atBottom =
          this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 20;
        this.setFollow(atBottom);
      });
      this.pill?.addEventListener("click", () => {
        this.setFollow(true);
        this.scroll();
      });
      this.scroll();
    },
    updated() {
      if (this.follow) this.scroll();
    },
    scroll() {
      this.el.scrollTop = this.el.scrollHeight;
    },
    setFollow(value) {
      this.follow = value;
      this.pill?.classList.toggle("hidden", value);
    },
  },
};

const csrf = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: { _csrf_token: csrf },
  hooks: Hooks,
});

liveSocket.connect();
