defmodule Jido.Shell.StreamJsonTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.StreamJson

  defmodule FakeShellAgent do
    def run(session_id, command, opts) do
      send(self(), {:shell_run, session_id, command, opts})
      Process.get(:stream_shell_result, {:ok, ""})
    end
  end

  defmodule FakeSessionServer do
    def subscribe(session_id, pid) do
      Process.put({:stream_subscriber, session_id}, pid)
      {:ok, :subscribed}
    end

    def unsubscribe(_session_id, _pid) do
      Process.put(:stream_unsubscribed, true)
      {:ok, :unsubscribed}
    end

    def run_command(session_id, command, opts) do
      send(self(), {:run_command, session_id, command, opts})

      case Process.get(:stream_run_result, {:ok, :accepted}) do
        {:ok, :accepted} = accepted ->
          subscriber = Process.get({:stream_subscriber, session_id}, self())

          Process.get(:stream_events, [])
          |> Enum.each(fn
            {:after, ms, message} -> Process.send_after(subscriber, message, ms)
            message -> send(subscriber, message)
          end)

          accepted

        other ->
          other
      end
    end
  end

  defmodule UnsupportedSessionServer do
  end

  test "streams JSON output and raw lines via ShellSessionServer" do
    session_id = "sess-stream-1"

    Process.put(:stream_events, [
      shell_event(session_id, :noise),
      shell_event(session_id, {:cwd_changed, "/tmp"}),
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, {:output, "{\"a\":1}\nraw "}),
      shell_event(session_id, {:output, "line\n{\"b\":2}\n"}),
      shell_event(session_id, :command_done)
    ])

    on_mode = fn mode -> send(self(), {:mode, mode}) end
    on_event = fn event -> send(self(), {:event, event}) end
    on_raw_line = fn line -> send(self(), {:raw, line}) end

    assert {:ok, output, events} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/work/o'hare",
               "echo stream",
               on_mode: on_mode,
               on_event: on_event,
               on_raw_line: on_raw_line,
               timeout: 1_000,
               heartbeat_interval_ms: 50
             )

    assert output == "{\"a\":1}\nraw line\n{\"b\":2}"
    assert events == [%{"a" => 1}, %{"b" => 2}]

    assert_receive {:mode, "session_server_stream"}
    assert_receive {:event, %{"a" => 1}}
    assert_receive {:event, %{"b" => 2}}
    assert_receive {:raw, "raw line"}

    assert_receive {:run_command, ^session_id, wrapped, [execution_context: %{max_runtime_ms: 1_000}]}
    assert wrapped == "cd '/work/o'\\''hare' && echo stream"
    assert Process.get(:stream_unsubscribed) == true
  end

  test "parses trailing JSON without newline on command completion" do
    session_id = "sess-stream-tail"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, {:output, "{\"tail\":1}"}),
      shell_event(session_id, :command_done)
    ])

    assert {:ok, "{\"tail\":1}", [%{"tail" => 1}]} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo tail",
               timeout: 500,
               heartbeat_interval_ms: 50
             )
  end

  test "returns cancelled error when command is cancelled" do
    session_id = "sess-stream-cancel"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, :command_cancelled)
    ])

    assert {:error, :cancelled} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo cancel",
               timeout: 500
             )
  end

  test "returns command crash reason when command crashes" do
    session_id = "sess-stream-crash"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, {:command_crashed, :boom})
    ])

    assert {:error, {:command_crashed, :boom}} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo crash",
               timeout: 500
             )
  end

  test "returns shell error events as errors" do
    session_id = "sess-stream-error"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, {:error, :bad_output})
    ])

    assert {:error, :bad_output} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo error",
               timeout: 500
             )
  end

  test "emits heartbeat callbacks while idle and before completion" do
    session_id = "sess-stream-heartbeat"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      {:after, 35, shell_event(session_id, :command_done)}
    ])

    on_heartbeat = fn idle_ms -> send(self(), {:heartbeat, idle_ms}) end

    assert {:ok, "", []} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo hb",
               timeout: 200,
               heartbeat_interval_ms: 10,
               on_heartbeat: on_heartbeat
             )

    assert_receive {:heartbeat, idle_ms}
    assert idle_ms >= 10
  end

  test "times out when stream never completes" do
    session_id = "sess-stream-timeout"
    Process.put(:stream_events, [shell_event(session_id, {:command_started, "ignored"})])

    assert {:error, :timeout} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo timeout",
               timeout: 20,
               heartbeat_interval_ms: 5
             )
  end

  test "falls back to shell agent when session server is unsupported" do
    Process.put(:stream_shell_result, {:ok, "{\"x\":1}\nraw\n"})

    on_mode = fn mode -> send(self(), {:mode, mode}) end
    on_event = fn event -> send(self(), {:event, event}) end
    on_raw_line = fn line -> send(self(), {:raw, line}) end

    assert {:ok, output, events} =
             StreamJson.run(
               FakeShellAgent,
               UnsupportedSessionServer,
               "sess-fallback-1",
               "/tmp/fallback",
               "echo fallback",
               on_mode: on_mode,
               on_event: on_event,
               on_raw_line: on_raw_line,
               timeout: 1_500
             )

    assert output == "{\"x\":1}\nraw"
    assert events == [%{"x" => 1}]

    assert_receive {:mode, "session_server_stream"}
    assert_receive {:mode, "shell_agent_fallback"}
    assert_receive {:event, %{"x" => 1}}
    assert_receive {:raw, "raw"}
    assert_receive {:shell_run, "sess-fallback-1", "cd '/tmp/fallback' && echo fallback", [timeout: 1_500]}
  end

  test "does not fall back when custom fallback eligibility rejects the reason" do
    fallback_eligible? = fn _ -> false end

    assert {:error, :unsupported_shell_session_server} =
             StreamJson.run(
               FakeShellAgent,
               UnsupportedSessionServer,
               "sess-fallback-no",
               "/tmp",
               "echo no",
               fallback_eligible?: fallback_eligible?
             )

    refute_receive {:shell_run, _, _, _}, 20
  end

  test "handles fallback eligibility callback failures safely" do
    fallback_eligible? = fn _ -> raise "callback failure" end

    assert {:error, :unsupported_shell_session_server} =
             StreamJson.run(
               FakeShellAgent,
               UnsupportedSessionServer,
               "sess-fallback-raise",
               "/tmp",
               "echo no",
               fallback_eligible?: fallback_eligible?
             )
  end

  test "can fallback from streaming run_command errors when explicitly allowed" do
    Process.put(:stream_run_result, {:error, :disconnected})
    Process.put(:stream_shell_result, {:ok, "{\"ok\":true}\n"})

    assert {:ok, "{\"ok\":true}", [%{"ok" => true}]} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               "sess-fallback-run-error",
               "/tmp",
               "echo ok",
               fallback_eligible?: fn :disconnected -> true end
             )
  end

  test "swallows callback failures" do
    session_id = "sess-callback-safe"

    Process.put(:stream_events, [
      shell_event(session_id, {:command_started, "ignored"}),
      shell_event(session_id, {:output, "{\"safe\":true}\nraw\n"}),
      shell_event(session_id, :command_done)
    ])

    assert {:ok, _output, [%{"safe" => true}]} =
             StreamJson.run(
               FakeShellAgent,
               FakeSessionServer,
               session_id,
               "/tmp",
               "echo safe",
               on_mode: fn _ -> raise "mode callback" end,
               on_event: fn _ -> raise "event callback" end,
               on_raw_line: fn _ -> raise "raw callback" end,
               on_heartbeat: fn _ -> raise "heartbeat callback" end,
               heartbeat_interval_ms: 5,
               timeout: 200
             )
  end

  defp shell_event(session_id, event), do: {:jido_shell_session, session_id, event}
end
