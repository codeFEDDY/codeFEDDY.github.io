using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace Clintware.QuillgeistLite
{
    [DataContract]
    public sealed class HealthConfig
    {
        [DataMember] public string Endpoint;
        [DataMember] public string DeviceId;
        [DataMember] public string Token;
        [DataMember] public string TaskName;
        [DataMember] public string RunnerPidPath;
        [DataMember] public string RunnerLogPath;
        [DataMember] public string CrashLogPath;
        [DataMember] public string LocalServiceLogPath;
        [DataMember] public string AutoRepairPath;
    }

    public sealed class QuillgeistLiteHealthService : ServiceBase
    {
        private readonly object gate = new object();
        private readonly Queue<DateTime> restarts = new Queue<DateTime>();
        private readonly Queue<DateTime> errorSignals = new Queue<DateTime>();
        private readonly Dictionary<string, long> offsets = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        private Timer timer;
        private HealthConfig config;
        private Thread wakeThread;
        private CancellationTokenSource wakeCancellation;
        private bool? previousRunnerAlive;
        private DateTime lastHeartbeat = DateTime.MinValue;
        private DateTime lastSuppressedNotice = DateTime.MinValue;
        private DateTime serviceStartedUtc = DateTime.MinValue;
        private DateTime lastRestartAttemptUtc = DateTime.MinValue;
        private DateTime lastAutoRepairAttemptUtc = DateTime.MinValue;
        private DateTime lastForcedWakeRestartUtc = DateTime.MinValue;
        private bool shuttingDown = false;

        public QuillgeistLiteHealthService()
        {
            ServiceName = "CodeFEDDYQQHealth";
            CanStop = true;
            CanShutdown = true;
            AutoLog = true;
        }

        protected override void OnStart(string[] args)
        {
            try
            {
                config = LoadConfig();
                serviceStartedUtc = DateTime.UtcNow;
                LocalLog("service_started");
                timer = new Timer(Tick, null, 1000, 5000);
                wakeCancellation = new CancellationTokenSource();
                wakeThread = new Thread(WakeLoop);
                wakeThread.IsBackground = true;
                wakeThread.Name = "QuillgeistLiteWake";
                wakeThread.Start();

                // Diagnostics uplink is useful but must never block SCM service startup.
                ThreadPool.QueueUserWorkItem(delegate {
                    try { TryPost("INFO", "service", "health_service_started", null); } catch { }
                });
            }
            catch (Exception ex)
            {
                StartupFailureLog(ex);
                throw;
            }
        }

        protected override void OnStop()
        {
            if (timer != null) timer.Dispose();
            try { if (wakeCancellation != null) wakeCancellation.Cancel(); } catch { }
            try { if (wakeThread != null && wakeThread.IsAlive) wakeThread.Join(3000); } catch { }
            TryPost("INFO", "service", "health_service_stopped", previousRunnerAlive);
            LocalLog("service_stopped");

            if (!shuttingDown && !MaintenanceModeActive())
            {
                ScheduleServiceRestart();
            }
        }

        protected override void OnShutdown()
        {
            shuttingDown = true;
            OnStop();
            base.OnShutdown();
        }

        private void StartupFailureLog(Exception ex)
        {
            try
            {
                string root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "Clintware", "QuillgeistLite");
                Directory.CreateDirectory(root);
                string path = Path.Combine(root, "service-startup-error.log");
                File.AppendAllText(path,
                    DateTime.UtcNow.ToString("o") + " " + ex.ToString() + Environment.NewLine);
            }
            catch { }
        }

        private HealthConfig LoadConfig()
        {
            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Clintware", "QuillgeistLite", "service.json");

            using (FileStream fs = File.OpenRead(path))
            {
                DataContractJsonSerializer serializer = new DataContractJsonSerializer(typeof(HealthConfig));
                HealthConfig loaded = (HealthConfig)serializer.ReadObject(fs);
                if (loaded == null || String.IsNullOrWhiteSpace(loaded.Endpoint) ||
                    String.IsNullOrWhiteSpace(loaded.DeviceId) || String.IsNullOrWhiteSpace(loaded.Token))
                {
                    throw new InvalidOperationException("Quillgeist Lite health service configuration is incomplete.");
                }
                return loaded;
            }
        }

        private void WakeLoop()
        {
            int backoffSeconds = 2;

            while (wakeCancellation != null && !wakeCancellation.IsCancellationRequested)
            {
                ClientWebSocket socket = null;
                try
                {
                    string baseEndpoint = config.Endpoint.TrimEnd('/');
                    Uri httpUri = new Uri(baseEndpoint);
                    string scheme = httpUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ? "wss" : "ws";
                    string wakeUrl = scheme + "://" + httpUri.Authority +
                        "/api/v1/quillgeist-lite/wake-stream?device_id=" + Uri.EscapeDataString(config.DeviceId);

                    socket = new ClientWebSocket();
                    socket.Options.SetRequestHeader("Authorization", "Bearer " + config.Token);

                    LocalLog("wake_channel_connecting");
                    socket.ConnectAsync(new Uri(wakeUrl), wakeCancellation.Token).GetAwaiter().GetResult();
                    LocalLog("wake_channel_connected");
                    TryPost("INFO", "wake", "wake_channel_connected", RunnerAlive());
                    backoffSeconds = 2;

                    byte[] buffer = new byte[8192];
                    ArraySegment<byte> segment = new ArraySegment<byte>(buffer);

                    while (!wakeCancellation.IsCancellationRequested &&
                           socket.State == WebSocketState.Open)
                    {
                        using (MemoryStream message = new MemoryStream())
                        {
                            WebSocketReceiveResult result;
                            do
                            {
                                result = socket.ReceiveAsync(segment, wakeCancellation.Token).GetAwaiter().GetResult();
                                if (result.MessageType == WebSocketMessageType.Close)
                                {
                                    try
                                    {
                                        socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "service_reconnect",
                                            CancellationToken.None).GetAwaiter().GetResult();
                                    }
                                    catch { }
                                    break;
                                }
                                message.Write(buffer, 0, result.Count);
                                if (message.Length > 65536) throw new InvalidOperationException("wake_message_too_large");
                            }
                            while (!result.EndOfMessage);

                            if (result.MessageType == WebSocketMessageType.Close) break;

                            string payload = Encoding.UTF8.GetString(message.ToArray());
                            if (payload.IndexOf("\"type\":\"wake\"", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                LocalLog("wake_received " + Redact(payload));
                                bool alive = RunnerAlive();
                                if (!alive)
                                {
                                    // A queued job can now wake qq even when its interactive
                                    // runner is not already connected.
                                    EnsureRunner(true);
                                }
                                else
                                {
                                    TryPost("INFO", "wake", "wake_received_runner_already_alive", true);
                                }
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    LocalLog("wake_channel_error " + Redact(ex.Message));
                }
                finally
                {
                    try { if (socket != null) socket.Dispose(); } catch { }
                }

                if (wakeCancellation == null || wakeCancellation.IsCancellationRequested) break;

                int delay = Math.Max(2, Math.Min(60, backoffSeconds));
                try
                {
                    if (wakeCancellation.Token.WaitHandle.WaitOne(TimeSpan.FromSeconds(delay))) break;
                }
                catch { }
                backoffSeconds = Math.Min(60, backoffSeconds * 2);
            }

            LocalLog("wake_channel_stopped");
        }

        private void Tick(object state)
        {
            if (!Monitor.TryEnter(gate)) return;
            try
            {
                bool alive = RunnerAlive();

                if (!previousRunnerAlive.HasValue || previousRunnerAlive.Value != alive)
                {
                    string message = alive ? "runner_state=alive" : "runner_state=down";
                    TryPost(alive ? "INFO" : "WARN", "health", message, alive);
                    LocalLog(message);
                    previousRunnerAlive = alive;
                }

                TailFile(config.CrashLogPath, "runner-crash", false);
                TailFile(config.RunnerLogPath, "runner-log", true);

                if (!alive && (DateTime.UtcNow - serviceStartedUtc).TotalSeconds >= 8)
                {
                    EnsureRunner(false);
                }

                if ((DateTime.UtcNow - lastHeartbeat).TotalMinutes >= 5)
                {
                    TryPost("INFO", "heartbeat", alive ? "runner_alive" : "runner_down", alive);
                    lastHeartbeat = DateTime.UtcNow;
                }
            }
            catch (Exception ex)
            {
                LocalLog("tick_error " + ex);
                TryPost("ERROR", "service", "watchdog_exception: " + Redact(ex.ToString()), previousRunnerAlive);
                RegisterErrorSignal("service_tick", ex.ToString());
            }
            finally
            {
                Monitor.Exit(gate);
            }
        }

        private bool MaintenanceModeActive()
        {
            try
            {
                string marker = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "Clintware", "QuillgeistLite", "maintenance.lock");
                if (!File.Exists(marker)) return false;

                DateTime ageBase = File.GetLastWriteTimeUtc(marker);
                if ((DateTime.UtcNow - ageBase).TotalMinutes <= 10) return true;

                try { File.Delete(marker); } catch { }
                return false;
            }
            catch
            {
                return false;
            }
        }

        private void ScheduleServiceRestart()
        {
            try
            {
                string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string cmd = Path.Combine(system, "cmd.exe");
                string args = "/c ping 127.0.0.1 -n 9 >nul & sc.exe start \"" +
                    ServiceName.Replace("\"", "") + "\" >nul 2>&1";
                ProcessStartInfo psi = new ProcessStartInfo(cmd, args);
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                Process.Start(psi);
                LocalLog("service_restart_deadman_armed");
            }
            catch (Exception ex)
            {
                LocalLog("service_restart_deadman_failed " + Redact(ex.Message));
            }
        }

        private bool RunnerAlive()
        {
            try
            {
                if (String.IsNullOrWhiteSpace(config.RunnerPidPath) || !File.Exists(config.RunnerPidPath)) return false;
                string raw = File.ReadAllText(config.RunnerPidPath).Trim();
                int pid;
                if (!Int32.TryParse(raw, out pid) || pid <= 0) return false;
                Process p = Process.GetProcessById(pid);
                return !p.HasExited;
            }
            catch
            {
                return false;
            }
        }

        private void EnsureRunner(bool forceWake = false)
        {
            DateTime now = DateTime.UtcNow;
            if ((now - lastRestartAttemptUtc).TotalSeconds < 15) return;

            DateTime cutoff = now.AddMinutes(-10);
            while (restarts.Count > 0 && restarts.Peek() < cutoff) restarts.Dequeue();

            if (restarts.Count >= 5)
            {
                if (forceWake && (now - lastForcedWakeRestartUtc).TotalSeconds >= 30)
                {
                    lastForcedWakeRestartUtc = now;
                    restarts.Clear();
                    string forced = "wake_bypassing_stale_restart_limit";
                    LocalLog(forced);
                    TryPost("WARN", "wake", forced, false);
                }
                else
                {
                    if ((now - lastSuppressedNotice).TotalMinutes >= 5)
                    {
                        string msg = "restart_suppressed_after_5_attempts_in_10_minutes";
                        LocalLog(msg);
                        TryPost("ERROR", "health", msg, false);
                        lastSuppressedNotice = now;
                    }
                    TryAutoRepair("restart_limit");
                    return;
                }
            }

            try
            {
                // Disabled tasks cannot be recovered by /Run. Re-enable first so
                // watchdog recovery is resilient to accidental/manual disablement.
                ProcessStartInfo enablePsi = new ProcessStartInfo("schtasks.exe",
                    "/Change /TN \"" + config.TaskName.Replace("\"", "\\\"") + "\" /ENABLE");
                enablePsi.CreateNoWindow = true;
                enablePsi.UseShellExecute = false;
                enablePsi.RedirectStandardOutput = true;
                enablePsi.RedirectStandardError = true;

                using (Process enable = Process.Start(enablePsi))
                {
                    enable.WaitForExit(10000);
                    string enableOut = enable.StandardOutput.ReadToEnd();
                    string enableErr = enable.StandardError.ReadToEnd();
                    string enableMsg = "runner_task_enable exit=" + enable.ExitCode;
                    if (!String.IsNullOrWhiteSpace(enableErr)) enableMsg += " stderr=" + Redact(enableErr);
                    else if (!String.IsNullOrWhiteSpace(enableOut)) enableMsg += " output=" + Redact(enableOut);
                    LocalLog(enableMsg);
                    TryPost(enable.ExitCode == 0 ? "INFO" : "WARN", "health", enableMsg, false);
                }

                // A Task Scheduler instance can remain marked Running after the real
                // runner process has died. With IgnoreNew, /Run then reports success
                // while doing nothing. End the stale wrapper first; a non-running task
                // simply returns a harmless non-zero code.
                ProcessStartInfo endPsi = new ProcessStartInfo("schtasks.exe",
                    "/End /TN \"" + config.TaskName.Replace("\"", "\\\"") + "\"");
                endPsi.CreateNoWindow = true;
                endPsi.UseShellExecute = false;
                endPsi.RedirectStandardOutput = true;
                endPsi.RedirectStandardError = true;

                using (Process end = Process.Start(endPsi))
                {
                    end.WaitForExit(10000);
                    string endOut = end.StandardOutput.ReadToEnd();
                    if (end.ExitCode == 0)
                    {
                        string ended = "stale_runner_task_ended";
                        if (!String.IsNullOrWhiteSpace(endOut)) ended += " output=" + Redact(endOut);
                        LocalLog(ended);
                        TryPost("WARN", "health", ended, false);
                        Thread.Sleep(750);
                    }
                }

                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe",
                    "/Run /TN \"" + config.TaskName.Replace("\"", "\\\"") + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit(15000);
                    string stdout = p.StandardOutput.ReadToEnd();
                    string stderr = p.StandardError.ReadToEnd();
                    lastRestartAttemptUtc = DateTime.UtcNow;
                    restarts.Enqueue(lastRestartAttemptUtc);

                    string msg = "runner_restart_requested exit=" + p.ExitCode;
                    if (!String.IsNullOrWhiteSpace(stderr)) msg += " stderr=" + Redact(stderr);
                    else if (!String.IsNullOrWhiteSpace(stdout)) msg += " output=" + Redact(stdout);

                    LocalLog(msg);
                    TryPost(p.ExitCode == 0 ? "WARN" : "ERROR", "health", msg, false);
                }
            }
            catch (Exception ex)
            {
                lastRestartAttemptUtc = DateTime.UtcNow;
                restarts.Enqueue(lastRestartAttemptUtc);
                string msg = "runner_restart_exception: " + Redact(ex.ToString());
                LocalLog(msg);
                TryPost("ERROR", "health", msg, false);
            }
        }

        private void TailFile(string path, string phase, bool errorsOnly)
        {
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;

            long offset;
            if (!offsets.TryGetValue(path, out offset)) offset = 0;

            FileInfo info = new FileInfo(path);
            if (info.Length < offset) offset = 0;
            if (info.Length == offset) return;

            List<string> selected = new List<string>();

            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Seek(offset, SeekOrigin.Begin);
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8, true, 4096, true))
                {
                    string line;
                    while ((line = sr.ReadLine()) != null)
                    {
                        if (!errorsOnly || IsImportantRunnerLine(line))
                        {
                            selected.Add(Redact(line));
                            if (selected.Count >= 20) break;
                        }
                    }
                }
                offsets[path] = fs.Position;
            }

            if (selected.Count == 0) return;

            string message = String.Join("\n", selected.ToArray());
            string level = phase == "runner-crash" ? "ERROR" : InferLevel(message);
            TryPost(level, phase, message, previousRunnerAlive);
            if (level == "ERROR") RegisterErrorSignal(phase, message);
        }

        private void RegisterErrorSignal(string source, string message)
        {
            DateTime now = DateTime.UtcNow;
            DateTime cutoff = now.AddMinutes(-2);
            while (errorSignals.Count > 0 && errorSignals.Peek() < cutoff) errorSignals.Dequeue();
            errorSignals.Enqueue(now);

            LocalLog("error_signal source=" + Redact(source) + " count_2m=" + errorSignals.Count);
            if (errorSignals.Count >= 3)
            {
                TryAutoRepair("error_burst:" + source);
                errorSignals.Clear();
            }
        }

        private string ResolvePowerShellHost()
        {
            try
            {
                string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                string pwsh = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
                if (File.Exists(pwsh)) return pwsh;
            }
            catch { }

            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            return Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
        }

        private void TryAutoRepair(string reason)
        {
            DateTime now = DateTime.UtcNow;
            if ((now - lastAutoRepairAttemptUtc).TotalMinutes < 30) return;

            string home = "";
            try { home = Path.GetDirectoryName(config.RunnerPidPath) ?? ""; } catch { }
            if (String.IsNullOrWhiteSpace(home))
            {
                LocalLog("auto_repair_home_unavailable");
                return;
            }

            string repairPath = config == null ? "" : (config.AutoRepairPath ?? "");
            if (String.IsNullOrWhiteSpace(repairPath))
            {
                repairPath = Path.Combine(home, "auto-repair-runtime.ps1");
            }

            if (!File.Exists(repairPath))
            {
                string unavailable = "auto_repair_unavailable reason=" + Redact(reason) + " path=" + Redact(repairPath);
                LocalLog(unavailable);
                TryPost("WARN", "auto-repair", unavailable, previousRunnerAlive);
                lastAutoRepairAttemptUtc = now;
                return;
            }

            lastAutoRepairAttemptUtc = now;
            string startMessage = "auto_repair_started reason=" + Redact(reason);
            LocalLog(startMessage);
            TryPost("WARN", "auto-repair", startMessage, previousRunnerAlive);

            try
            {
                string host = ResolvePowerShellHost();
                ProcessStartInfo psi = new ProcessStartInfo(
                    host,
                    "-NoProfile -ExecutionPolicy Bypass -File \"" +
                    repairPath.Replace("\"", "\\\"") +
                    "\" -HomeDir \"" + home.Replace("\"", "\\\"") + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = Process.Start(psi))
                {
                    if (!p.WaitForExit(120000))
                    {
                        try { p.Kill(); } catch { }
                        throw new System.TimeoutException("auto_repair_timeout");
                    }

                    string stdout = p.StandardOutput.ReadToEnd();
                    string stderr = p.StandardError.ReadToEnd();
                    string detail = "auto_repair_complete exit=" + p.ExitCode;
                    if (!String.IsNullOrWhiteSpace(stdout)) detail += " output=" + Redact(stdout);
                    if (!String.IsNullOrWhiteSpace(stderr)) detail += " stderr=" + Redact(stderr);

                    LocalLog(detail);
                    TryPost(p.ExitCode == 0 ? "INFO" : "ERROR", "auto-repair", detail, RunnerAlive());
                }
            }
            catch (Exception ex)
            {
                string failed = "auto_repair_failed: " + Redact(ex.ToString());
                LocalLog(failed);
                TryPost("ERROR", "auto-repair", failed, RunnerAlive());
            }
        }

        private bool IsImportantRunnerLine(string line)
        {
            if (String.IsNullOrEmpty(line)) return false;
            string s = line.ToUpperInvariant();
            return s.Contains("[ERROR]") || s.Contains("[WARN]") ||
                   s.Contains("FULL_EXCEPTION") || s.Contains("EXCEPTION") ||
                   s.Contains("CONNECTION ERROR") || s.Contains("FAILED");
        }

        private string InferLevel(string message)
        {
            string s = (message ?? "").ToUpperInvariant();
            if (s.Contains("[ERROR]") || s.Contains("EXCEPTION") || s.Contains("FAILED")) return "ERROR";
            if (s.Contains("[WARN]") || s.Contains("WARNING")) return "WARN";
            return "INFO";
        }

        private void TryPost(string level, string phase, string message, bool? runnerAlive)
        {
            try
            {
                string endpoint = config.Endpoint.TrimEnd('/') + "/api/v1/quillgeist-lite/diagnostics";
                string payload =
                    "{\"device_id\":\"" + Json(config.DeviceId) +
                    "\",\"level\":\"" + Json(level) +
                    "\",\"phase\":\"" + Json(phase) +
                    "\",\"message\":\"" + Json(Redact(message)) +
                    "\",\"runner_alive\":" + (runnerAlive.HasValue ? (runnerAlive.Value ? "true" : "false") : "null") +
                    ",\"service_version\":\"1.2.3\",\"timestamp\":\"" + DateTime.UtcNow.ToString("o") + "\"}";

                using (WebClient wc = new WebClient())
                {
                    wc.Headers[HttpRequestHeader.Authorization] = "Bearer " + config.Token;
                    wc.Headers[HttpRequestHeader.ContentType] = "application/json";
                    wc.UploadString(endpoint, "POST", payload);
                }
            }
            catch (Exception ex)
            {
                LocalLog("uplink_error " + ex.Message);
            }
        }

        private string Redact(string input)
        {
            string s = input ?? "";
            if (!String.IsNullOrWhiteSpace(config.Token))
            {
                s = s.Replace(config.Token, "[REDACTED]");
            }
            if (s.Length > 8000) s = s.Substring(0, 8000) + " ...[truncated]";
            return s;
        }

        private string Json(string input)
        {
            return (input ?? "")
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\r", "\\r")
                .Replace("\n", "\\n")
                .Replace("\t", "\\t");
        }

        private void LocalLog(string message)
        {
            try
            {
                string path = config != null && !String.IsNullOrWhiteSpace(config.LocalServiceLogPath)
                    ? config.LocalServiceLogPath
                    : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                        "Clintware", "QuillgeistLite", "service-local.log");
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + Redact(message) + Environment.NewLine);
            }
            catch { }
        }

        public static void Main()
        {
            ServiceBase.Run(new QuillgeistLiteHealthService());
        }
    }
}

