#!/usr/bin/env node
// Full-stack benchmark for installed iMCP. stdout is one JSON object only.
// Run it through Scripts/measure-full-stack-performance.sh, which passes the
// install's paths and pauses everything that would relaunch the app. It
// terminates and relaunches the app at --app, which ends every connected
// client's session. Requests use tools/list or an invalid utilities_beep
// payload, so no user data is returned or persisted and no beep is produced.

import { execFile, execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";

function parseArgs(argv) {
    const args = { app: null, appExecutable: null, binary: null, runs: 5, startupRuns: 3, loadCalls: 100, cpuLoadMs: 3000, concurrency: 4, timeoutMs: 20000 };
    for (let i = 0; i < argv.length; i += 1) {
        const flag = argv[i];
        const value = argv[++i];
        if (flag === "--app") args.app = value;
        else if (flag === "--app-executable") args.appExecutable = value;
        else if (flag === "--binary") args.binary = value;
        else if (flag === "--runs") args.runs = Number(value);
        else if (flag === "--startup-runs") args.startupRuns = Number(value);
        else if (flag === "--load-calls") args.loadCalls = Number(value);
        else if (flag === "--cpu-load-ms") args.cpuLoadMs = Number(value);
        else if (flag === "--concurrency") args.concurrency = Number(value);
        else if (flag === "--timeout-ms") args.timeoutMs = Number(value);
        else throw new Error(`unknown flag: ${flag}`);
    }
    for (const key of ["runs", "startupRuns", "loadCalls", "cpuLoadMs", "concurrency", "timeoutMs"]) {
        if (!Number.isFinite(args[key]) || args[key] < 1) throw new Error(`${key} must be >= 1`);
    }
    for (const key of ["app", "appExecutable", "binary"]) {
        if (!args[key]) throw new Error(`${key} is required`);
    }
    return args;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const now = () => process.hrtime.bigint();
const elapsedMs = (start) => Number(process.hrtime.bigint() - start) / 1e6;
const round = (value, places = 2) => value === null ? null : Number(value.toFixed(places));

function percentile(values, fraction) {
    if (values.length === 0) return null;
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.max(0, Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1))];
}

const median = (values) => percentile(values, 0.5);

// Set in main() from --app-executable. Matching the executable path leaves an
// Xcode-run build and the XCTest host, which are also processes named iMCP,
// alone. `ps comm` is the launch path, not the bundle a process came from
// (Scripts/lib/imcp.sh reads lsof text mappings for that); it is enough here
// only because this script launches the app itself, by that path.
let appExecutable = null;

function appPids() {
    try {
        return execFileSync("/bin/ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
            .split("\n")
            .map((line) => line.trim().match(/^(\d+)\s+(.*)$/))
            .filter((match) => match && match[2] === appExecutable)
            .map((match) => Number(match[1]));
    } catch {
        return [];
    }
}

function processStats(pids) {
    if (pids.length === 0) return { rssMb: null, cpu: null };
    try {
        const output = execFileSync("/bin/ps", ["-o", "rss=,%cpu=", "-p", pids.join(",")], { encoding: "utf8" });
        let rssKb = 0;
        let cpu = 0;
        let count = 0;
        for (const line of output.trim().split("\n")) {
            const [rss, percent] = line.trim().split(/\s+/).map(Number);
            if (Number.isFinite(rss) && Number.isFinite(percent)) {
                rssKb += rss;
                cpu += percent;
                count += 1;
            }
        }
        return count ? { rssMb: rssKb / 1024, cpu } : { rssMb: null, cpu: null };
    } catch {
        return { rssMb: null, cpu: null };
    }
}

class MCPSession {
    constructor(binary, timeoutMs) {
        this.binary = binary;
        this.timeoutMs = timeoutMs;
        this.child = null;
        this.buffer = "";
        this.nextID = 1;
        this.pending = new Map();
        this.peakRssMb = 0;
    }

    async start() {
        this.child = spawn(this.binary, [], { stdio: ["pipe", "pipe", "pipe"] });
        this.child.stderr.resume();
        this.child.stdout.on("data", (chunk) => this.receive(chunk));
        this.child.on("exit", (code, signal) => this.failAll(new Error(`imcp-server exited (${code ?? signal})`)));
        this.child.on("error", (error) => this.failAll(error));
        this.child.stdin.on("error", (error) => this.failAll(error));
        await this.request("initialize", {
            protocolVersion: "2025-06-18",
            capabilities: {},
            clientInfo: { name: "imcp-full-stack-benchmark", version: "1.0.0" },
        });
        this.notify("notifications/initialized", {});
        return this;
    }

    receive(chunk) {
        this.buffer += chunk.toString("utf8");
        let newline;
        while ((newline = this.buffer.indexOf("\n")) !== -1) {
            const line = this.buffer.slice(0, newline);
            this.buffer = this.buffer.slice(newline + 1);
            let message;
            try { message = JSON.parse(line); } catch { continue; }
            const pending = this.pending.get(message.id);
            if (!pending) continue;
            this.pending.delete(message.id);
            clearTimeout(pending.timer);
            pending.resolve({ message, bytes: Buffer.byteLength(line, "utf8") });
        }
    }

    failAll(error) {
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timer);
            pending.reject(error);
        }
        this.pending.clear();
    }

    request(method, params) {
        const id = this.nextID++;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error(`${method} timed out after ${this.timeoutMs}ms`));
            }, this.timeoutMs);
            this.pending.set(id, { resolve, reject, timer });
            this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
        });
    }

    notify(method, params) {
        this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
    }

    sampleCLI() {
        const stats = processStats([this.child.pid]);
        if (stats.rssMb !== null) this.peakRssMb = Math.max(this.peakRssMb, stats.rssMb);
    }

    close() {
        this.failAll(new Error("session closed"));
        try { this.child.stdin.end(); } catch {}
        try { this.child.kill("SIGTERM"); } catch {}
    }
}

function openApp(app) {
    return new Promise((resolve, reject) => {
        execFile("/usr/bin/open", ["-gja", app], (error) => error ? reject(error) : resolve());
    });
}

async function waitForExit(pids, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (!pids.some((pid) => appPids().includes(pid))) return;
        await sleep(25);
    }
    throw new Error("iMCP did not exit before startup benchmark");
}

async function readySession(args, deadline) {
    let lastError;
    while (Date.now() < deadline) {
        const session = new MCPSession(args.binary, Math.min(3000, args.timeoutMs));
        try {
            await session.start();
            await session.request("tools/list", {});
            return session;
        } catch (error) {
            lastError = error;
            session.close();
            await sleep(50);
        }
    }
    throw lastError ?? new Error("iMCP readiness timed out");
}

// A client key the app has not approved parks initialize behind an approval
// prompt, and the relaunch loop below would retry it until every deadline
// expired. Try once, up front, and say how to fix it.
async function preflight(args) {
    const session = new MCPSession(args.binary, args.timeoutMs);
    try {
        await session.start();
        await session.request("tools/list", {});
    } catch (error) {
        if (/initialize timed out/.test(error.message)) {
            throw new Error(
                "initialize timed out: this client key is not approved. Approve it in iMCP, " +
                "or set IMCP_KEY_FILE to an approved client key (Debug builds only)"
            );
        }
        throw error;
    } finally {
        session.close();
    }
}

async function benchmarkStartup(args) {
    const samples = [];
    for (let i = 0; i < args.startupRuns; i += 1) {
        const prior = appPids();
        for (const pid of prior) {
            try { process.kill(pid, "SIGTERM"); } catch {}
        }
        await waitForExit(prior, 5000);
        const started = now();
        await openApp(args.app);
        const session = await readySession(args, Date.now() + args.timeoutMs);
        samples.push(elapsedMs(started));
        session.close();
        process.stderr.write(`startup ${i + 1}/${args.startupRuns}: ${round(samples.at(-1))}ms\n`);
        await sleep(250);
    }
    return samples;
}

async function sampleDuring(promise, sessions) {
    const samples = [];
    let complete = false;
    const tracked = promise.finally(() => { complete = true; });
    while (!complete) {
        samples.push(processStats(appPids()));
        for (const session of sessions) session.sampleCLI();
        await Promise.race([tracked.catch(() => {}), sleep(50)]);
    }
    samples.push(processStats(appPids()));
    return { result: await tracked, samples };
}

async function parallelRequests(sessions, count, makeRequest) {
    let cursor = 0;
    const workers = sessions.map(async (session) => {
        const results = [];
        while (cursor < count) {
            cursor += 1;
            results.push(await makeRequest(session));
        }
        return results;
    });
    return (await Promise.all(workers)).flat();
}

async function sustainedRequests(sessions, durationMs, makeRequest) {
    const deadline = Date.now() + durationMs;
    await Promise.all(sessions.map(async (session) => {
        while (Date.now() < deadline) await makeRequest(session);
    }));
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (!existsSync(args.app) || !existsSync(args.binary)) throw new Error("app or binary missing");
    appExecutable = args.appExecutable;

    const initiallyRunning = appPids().length > 0;
    let restored = false;
    const restore = async () => {
        if (restored) return;
        restored = true;
        if (initiallyRunning && appPids().length === 0) await openApp(args.app).catch(() => {});
        if (!initiallyRunning) {
            for (const pid of appPids()) {
                try { process.kill(pid, "SIGTERM"); } catch {}
            }
        }
    };
    process.once("SIGINT", () => { restore().finally(() => process.exit(130)); });
    process.once("SIGTERM", () => { restore().finally(() => process.exit(143)); });

    try {
        if (!initiallyRunning) await openApp(args.app);
        await preflight(args);
        const startup = await benchmarkStartup(args);
        await sleep(500);

        const sessions = [];
        for (let i = 0; i < args.concurrency; i += 1) sessions.push(await new MCPSession(args.binary, args.timeoutMs).start());
        const totalCalls = args.loadCalls * args.runs;
        const steadySamples = [];
        for (let i = 0; i < 5; i += 1) {
            steadySamples.push(processStats(appPids()).rssMb);
            await sleep(100);
        }

        const dispatchWork = parallelRequests(sessions, totalCalls, async (session) => {
            const started = now();
            // Invalid enum value reaches application dispatch and fails before
            // NSSound, keeping repeated measurements silent and side-effect free.
            const { message } = await session.request("tools/call", {
                name: "utilities_beep",
                arguments: { sound: "__imcp_benchmark_invalid__" },
            });
            if (!message.error && message.result?.isError !== true) {
                throw new Error("utilities_beep accepted the invalid sound; dispatch was not measured");
            }
            return elapsedMs(started);
        });
        const dispatchMeasured = await sampleDuring(dispatchWork, sessions);

        const cpuWork = sustainedRequests(sessions, args.cpuLoadMs, async (session) => {
            await session.request("tools/call", {
                name: "utilities_beep",
                arguments: { sound: "__imcp_benchmark_invalid__" },
            });
        });
        const cpuMeasured = await sampleDuring(cpuWork, sessions);

        const listStart = now();
        const listWork = parallelRequests(sessions, totalCalls, async (session) => session.request("tools/list", {}));
        const listMeasured = await sampleDuring(listWork, sessions);
        const listElapsed = elapsedMs(listStart);
        const listResponses = listMeasured.result;
        const listBytes = listResponses.reduce((sum, item) => sum + item.bytes, 0);
        const toolCounts = listResponses.map(({ message }) => Array.isArray(message.result?.tools) ? message.result.tools.length : -1);
        const uniqueToolCounts = [...new Set(toolCounts)];

        const allLoadSamples = [...dispatchMeasured.samples, ...cpuMeasured.samples, ...listMeasured.samples];
        const rssValues = allLoadSamples.map((sample) => sample.rssMb).filter(Number.isFinite);
        const cpuValues = cpuMeasured.samples.map((sample) => sample.cpu).filter(Number.isFinite);
        const dispatch = dispatchMeasured.result;
        const cliPeak = Math.max(...sessions.map((session) => session.peakRssMb));
        sessions.forEach((session) => session.close());

        const output = {
            mcp_dispatch_p50_ms: round(median(dispatch)),
            startup_p50_ms: round(median(startup)),
            steady_rss_mb: round(median(steadySamples.filter(Number.isFinite))),
            load_cpu_percent: round(median(cpuValues)),
            tools_list_throughput_mbps: round(listElapsed > 0 ? (listBytes * 8) / (listElapsed * 1000) : null, 4),
            tool_count_stable: uniqueToolCounts.length === 1 && uniqueToolCounts[0] > 0,
            mcp_dispatch_p95_ms: round(percentile(dispatch, 0.95)),
            startup_p95_ms: round(percentile(startup, 0.95)),
            peak_rss_mb: round(rssValues.length ? Math.max(...rssValues) : null),
            cli_peak_rss_mb: round(Number.isFinite(cliPeak) ? cliPeak : null),
            tools_list_bytes: round(median(listResponses.map((item) => item.bytes)), 0),
            calls_per_second: round(listElapsed > 0 ? listResponses.length * 1000 / listElapsed : null),
        };
        console.log(JSON.stringify(output));
    } finally {
        await restore();
    }
}

main().catch((error) => {
    console.log(JSON.stringify({ harness_error: error.message }));
    process.exitCode = 2;
});
