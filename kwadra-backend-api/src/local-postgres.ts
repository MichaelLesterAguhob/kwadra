import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile, unlink } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import pg from "pg";
import path from "node:path";
import { root } from "./config.js";

const run = promisify(execFile);
// Use the pinned package's platform binaries and PostgreSQL's own lifecycle
// manager. pg_ctl performs a graceful fast shutdown on Windows, unlike killing
// the database process tree. Never manage an unrelated system service.
class LocalCluster {
  constructor(
    private directory: string,
    private port: number,
    private password: string,
  ) {}
  private async binaries(): Promise<{ initdb: string; pg_ctl: string }> {
    const platform =
      process.platform === "win32" ? "windows" : process.platform;
    return import(`@embedded-postgres/${platform}-${process.arch}`);
  }
  async initialise() {
    const { initdb } = await this.binaries(),
      pwfile = path.join(this.directory, "init-password");
    await writeFile(pwfile, this.password, { mode: 0o600, flag: "wx" });
    try {
      await run(
        initdb,
        [
          "-D",
          path.join(this.directory, "data"),
          "-U",
          "kwadra_admin",
          "--encoding=UTF8",
          "--locale=C",
          "--auth-local=scram-sha-256",
          "--auth-host=scram-sha-256",
          "--pwfile=" + pwfile,
        ],
        { windowsHide: true, timeout: 60000 },
      );
    } finally {
      await unlink(pwfile);
    }
  }
  async start() {
    const { pg_ctl } = await this.binaries();
    try {
      await run(pg_ctl, ["status", "-D", path.join(this.directory, "data")], {
        windowsHide: true,
      });
      return;
    } catch {
      /* A stopped cluster can be started without changing existing data. */
    }
    await run(
      pg_ctl,
      [
        "start",
        "-D",
        path.join(this.directory, "data"),
        "-l",
        path.join(this.directory, "postgres.log"),
        "-o",
        `-p ${this.port} -h 127.0.0.1`,
        "-w",
        "-t",
        "30",
      ],
      { windowsHide: true, timeout: 40000 },
    );
  }
  async stop() {
    const { pg_ctl } = await this.binaries();
    await run(
      pg_ctl,
      [
        "stop",
        "-D",
        path.join(this.directory, "data"),
        "-m",
        "fast",
        "-w",
        "-t",
        "30",
      ],
      { windowsHide: true, timeout: 40000 },
    );
  }
  getPgClient(database: string, host: string) {
    return new pg.Client({
      host,
      port: this.port,
      database,
      user: "kwadra_admin",
      password: this.password,
    });
  }
}

export async function localPostgres(
  options: { directory?: string; port?: number } = {},
) {
  const directory = options.directory ?? path.join(root, ".local", "postgres");
  const port = options.port ?? 55432;
  await mkdir(directory, { recursive: true });
  const credentialsFile = path.join(directory, "credentials.json");
  let credentials: { admin: string; app: string };
  if (existsSync(credentialsFile))
    credentials = JSON.parse(await readFile(credentialsFile, "utf8"));
  else {
    credentials = {
      admin: randomBytes(24).toString("hex"),
      app: randomBytes(24).toString("hex"),
    };
    await writeFile(credentialsFile, JSON.stringify(credentials), {
      mode: 0o600,
      flag: "wx",
    });
  }
  const cluster = new LocalCluster(directory, port, credentials.admin);
  if (!existsSync(path.join(directory, "data", "PG_VERSION")))
    await cluster.initialise();
  await cluster.start();
  const admin = cluster.getPgClient("postgres", "127.0.0.1");
  await admin.connect();
  try {
    if (
      !(await admin.query("SELECT 1 FROM pg_roles WHERE rolname='kwadra_app'"))
        .rowCount
    ) {
      // Password is generated hex, not user input. PostgreSQL does not accept
      // parameters in CREATE ROLE. No admin credentials enter the API pool.
      await admin.query(
        `CREATE ROLE kwadra_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${credentials.app}'`,
      );
    }
    if (
      !(await admin.query("SELECT 1 FROM pg_database WHERE datname='kwadra'"))
        .rowCount
    )
      await admin.query("CREATE DATABASE kwadra OWNER kwadra_app");
  } finally {
    await admin.end();
  }
  return {
    cluster,
    url: `postgresql://kwadra_app:${credentials.app}@127.0.0.1:${port}/kwadra`,
  };
}
