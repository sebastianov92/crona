import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { api, ApiError, connectWS, session } from "./api";
import type { Instance, ScheduledMessage, User, Paginated } from "./types";
import Scheduled from "./views/Scheduled";
import History from "./views/History";
import Settings from "./views/Settings";

export interface AppState {
  user: User;
  instances: Instance[];
  upcoming: ScheduledMessage[];
  refreshInstances: () => Promise<void>;
  refreshMessages: () => Promise<void>;
  setUser: (u: User) => void;
  logout: () => void;
  toast: (msg: string) => void;
}

const Ctx = createContext<AppState | null>(null);
export const useApp = () => useContext(Ctx)!;

type Theme = "system" | "light" | "dark";

function applyTheme(t: Theme) {
  const dark = t === "dark" || (t === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

export function useTheme(): [Theme, (t: Theme) => void] {
  const [theme, setTheme] = useState<Theme>((localStorage.getItem("theme") as Theme) || "system");
  useEffect(() => {
    applyTheme(theme);
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const fn = () => theme === "system" && applyTheme("system");
    mq.addEventListener("change", fn);
    return () => mq.removeEventListener("change", fn);
  }, [theme]);
  return [
    theme,
    (t) => {
      localStorage.setItem("theme", t);
      setTheme(t);
    },
  ];
}

export default function App() {
  const [phase, setPhase] = useState<"loading" | "login" | "ready">("loading");
  const [user, setUser] = useState<User | null>(null);
  useTheme();

  useEffect(() => {
    (async () => {
      if (await session.tryRestore()) {
        try {
          setUser(await api<User>("GET", "/me"));
          setPhase("ready");
          return;
        } catch {
          /* cae al login */
        }
      }
      setPhase("login");
    })();
  }, []);

  if (phase === "loading")
    return (
      <div className="center">
        <img src="/app/icon.png" width={84} style={{ borderRadius: 20 }} />
      </div>
    );
  if (phase === "login" || !user)
    return (
      <Login
        onDone={(u) => {
          setUser(u);
          setPhase("ready");
        }}
      />
    );
  return <Main user={user} onLogout={() => setPhase("login")} />;
}

function Login({ onDone }: { onDone: (u: User) => void }) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [invite, setInvite] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    setError("");
    try {
      const r = await api<{ accessToken: string; refreshToken: string; user: User }>(
        "POST",
        mode === "login" ? "/auth/login" : "/auth/register",
        mode === "login" ? { email, password } : { email, password, name, inviteCode: invite || undefined },
      );
      session.setTokens(r.accessToken, r.refreshToken);
      onDone(r.user);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "No se pudo conectar al servidor.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="center">
      <div className="authbox">
        <img className="logo" src="/app/icon.png" />
        <h1 style={{ textAlign: "center", marginBottom: 8 }}>Crona</h1>
        {mode === "register" && (
          <input className="field" placeholder="Nombre" value={name} onChange={(e) => setName(e.target.value)} />
        )}
        <input className="field" type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <input
          className="field"
          type="password"
          placeholder="Contraseña"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
        />
        {mode === "register" && (
          <>
            <input className="field" placeholder="Código de invitación (si te dieron uno)" value={invite} onChange={(e) => setInvite(e.target.value)} />
            <div className="hint">El primer usuario del servidor no necesita invitación.</div>
          </>
        )}
        {error && <div className="error">{error}</div>}
        <button className="btn" disabled={busy || !email || password.length < 8} onClick={submit}>
          {busy ? <span className="spin" /> : mode === "login" ? "Entrar" : "Crear cuenta"}
        </button>
        <button className="btn ghost" style={{ margin: "0 auto" }} onClick={() => setMode(mode === "login" ? "register" : "login")}>
          {mode === "login" ? "Crear cuenta" : "Ya tengo cuenta"}
        </button>
      </div>
    </div>
  );
}

function Main({ user: initialUser, onLogout }: { user: User; onLogout: () => void }) {
  const [tab, setTab] = useState<"scheduled" | "history" | "settings">("scheduled");
  const [user, setUser] = useState(initialUser);
  const [instances, setInstances] = useState<Instance[]>([]);
  const [upcoming, setUpcoming] = useState<ScheduledMessage[]>([]);
  const [toastMsg, setToastMsg] = useState("");

  const refreshInstances = useCallback(async () => {
    try {
      setInstances((await api<Paginated<Instance>>("GET", "/instances")).items);
    } catch {
      /* toast opcional */
    }
  }, []);

  const refreshMessages = useCallback(async () => {
    try {
      setUpcoming((await api<Paginated<ScheduledMessage>>("GET", "/messages?filter=upcoming")).items);
    } catch {
      /* */
    }
  }, []);

  useEffect(() => {
    refreshInstances();
    refreshMessages();
    const off = connectWS((type, payload) => {
      if (type === "message.updated") {
        const msg = payload as ScheduledMessage;
        setUpcoming((prev) => {
          const rest = prev.filter((m) => m.id !== msg.id);
          const next = msg.status === "ACTIVE" || msg.status === "PAUSED" ? [...rest, msg] : rest;
          return next.sort((a, b) => a.nextRunAt.localeCompare(b.nextRunAt));
        });
      }
      if (type === "instance.updated") {
        const inst = payload as Instance;
        setInstances((prev) => prev.map((i) => (i.id === inst.id ? inst : i)));
      }
    });
    const onFocus = () => {
      refreshInstances();
      refreshMessages();
    };
    window.addEventListener("focus", onFocus);
    return () => {
      off();
      window.removeEventListener("focus", onFocus);
    };
  }, [refreshInstances, refreshMessages]);

  const toast = useCallback((msg: string) => {
    setToastMsg(msg);
    setTimeout(() => setToastMsg(""), 4000);
  }, []);

  const state: AppState = {
    user,
    instances,
    upcoming,
    refreshInstances,
    refreshMessages,
    setUser,
    logout: async () => {
      await session.logout();
      onLogout();
    },
    toast,
  };

  const tabs = [
    { id: "scheduled" as const, label: "Programados", icon: "🕐" },
    { id: "history" as const, label: "Historial", icon: "🕘" },
    { id: "settings" as const, label: "Ajustes", icon: "⚙️" },
  ];

  return (
    <Ctx.Provider value={state}>
      <div className="shell">
        <nav className="sidebar">
          <div className="logo">
            <img src="/app/icon.png" /> Crona
          </div>
          {tabs.map((t) => (
            <button key={t.id} className={`navbtn ${tab === t.id ? "active" : ""}`} onClick={() => setTab(t.id)}>
              <span>{t.icon}</span> {t.label}
            </button>
          ))}
        </nav>
        <main className="content">
          {tab === "scheduled" && <Scheduled />}
          {tab === "history" && <History />}
          {tab === "settings" && <Settings />}
        </main>
        <nav className="tabbar">
          {tabs.map((t) => (
            <button key={t.id} className={tab === t.id ? "active" : ""} onClick={() => setTab(t.id)}>
              <span className="icon">{t.icon}</span>
              {t.label}
            </button>
          ))}
        </nav>
        {toastMsg && (
          <div style={{ position: "fixed", bottom: 90, left: "50%", transform: "translateX(-50%)", zIndex: 200 }} className="banner">
            {toastMsg}
          </div>
        )}
      </div>
    </Ctx.Provider>
  );
}
