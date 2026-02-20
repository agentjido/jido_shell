defmodule Jido.Shell.StreamJson do
  @moduledoc """
  Run a command and parse line-delimited JSON output with optional callbacks.

  This module prefers `ShellSessionServer` streaming and can fall back to
  direct `shell_agent_mod.run/3` execution when configured.
  """

  alias Jido.Shell.Exec

  @default_timeout 300_000
  @default_heartbeat_interval_ms 5_000

  @type mode_callback :: (String.t() -> any())
  @type event_callback :: (map() -> any())
  @type raw_line_callback :: (String.t() -> any())
  @type heartbeat_callback :: (non_neg_integer() -> any())
  @type fallback_eligible_callback :: (term() -> boolean())

  @spec run(module(), module(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, term()}
  def run(shell_agent_mod, session_server_mod, session_id, cwd, command, opts \\ [])
      when is_atom(shell_agent_mod) and is_atom(session_server_mod) and is_binary(session_id) and
             is_binary(cwd) and is_binary(command) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    heartbeat_interval_ms = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    on_mode = Keyword.get(opts, :on_mode)
    on_event = Keyword.get(opts, :on_event)
    on_raw_line = Keyword.get(opts, :on_raw_line)
    on_heartbeat = Keyword.get(opts, :on_heartbeat)

    fallback_eligible? =
      case Keyword.get(opts, :fallback_eligible?) do
        fun when is_function(fun, 1) -> fun
        _ -> &default_fallback_eligible?/1
      end

    safe_callback(on_mode, "session_server_stream")

    case run_streaming_via_session_server(
           session_server_mod,
           session_id,
           cwd,
           command,
           timeout,
           heartbeat_interval_ms,
           on_event,
           on_raw_line,
           on_heartbeat
         ) do
      {:ok, _output, _events} = ok ->
        ok

      {:error, reason} ->
        if safe_fallback_eligible?(fallback_eligible?, reason) do
          safe_callback(on_mode, "shell_agent_fallback")

          with {:ok, output} <-
                 Exec.run_in_dir(shell_agent_mod, session_id, cwd, command, timeout: timeout) do
            events = parse_all_stream_lines(output, on_event, on_raw_line)
            {:ok, output, events}
          end
        else
          {:error, reason}
        end
    end
  end

  defp run_streaming_via_session_server(
         session_server_mod,
         session_id,
         cwd,
         command,
         timeout,
         heartbeat_interval_ms,
         on_event,
         on_raw_line,
         on_heartbeat
       ) do
    wrapped = "cd #{Exec.escape_path(cwd)} && #{command}"

    with :ok <- ensure_session_server_api(session_server_mod),
         {:ok, :subscribed} <- session_server_mod.subscribe(session_id, self()) do
      try do
        drain_shell_events(session_id)

        deadline_ms = monotonic_ms() + timeout

        case session_server_mod.run_command(session_id, wrapped, execution_context: %{max_runtime_ms: timeout}) do
          {:ok, :accepted} ->
            collect_stream_output(
              session_id,
              deadline_ms,
              heartbeat_interval_ms,
              on_event,
              on_raw_line,
              on_heartbeat,
              "",
              [],
              [],
              false,
              monotonic_ms()
            )

          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = session_server_mod.unsubscribe(session_id, self())
      end
    end
  end

  defp ensure_session_server_api(mod) when is_atom(mod) do
    if function_exported?(mod, :subscribe, 2) and
         function_exported?(mod, :unsubscribe, 2) and
         function_exported?(mod, :run_command, 3) do
      :ok
    else
      {:error, :unsupported_shell_session_server}
    end
  end

  defp default_fallback_eligible?(:unsupported_shell_session_server), do: true
  defp default_fallback_eligible?(%Jido.Shell.Error{code: {:session, :not_found}}), do: true
  defp default_fallback_eligible?(_), do: false

  defp safe_fallback_eligible?(fun, reason) when is_function(fun, 1) do
    fun.(reason) == true
  rescue
    _ -> false
  end

  defp collect_stream_output(
         session_id,
         deadline_ms,
         heartbeat_interval_ms,
         on_event,
         on_raw_line,
         on_heartbeat,
         line_buffer,
         output_acc,
         event_acc,
         started?,
         last_event_ms
       ) do
    now = monotonic_ms()
    remaining = deadline_ms - now

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:jido_shell_session, ^session_id, {:command_started, _line}} ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            true,
            last_event_ms
          )

        {:jido_shell_session, ^session_id, {:output, chunk}} ->
          {next_buffer, parsed_events, parsed_any?} =
            consume_stream_chunk(line_buffer, chunk, on_event, on_raw_line)

          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            next_buffer,
            [chunk | output_acc],
            Enum.reverse(parsed_events) ++ event_acc,
            started?,
            if(parsed_any?, do: monotonic_ms(), else: last_event_ms)
          )

        {:jido_shell_session, ^session_id, {:cwd_changed, _}} ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )

        {:jido_shell_session, ^session_id, :command_done} ->
          {trailing_events, trailing_any?} = parse_tail_buffer(line_buffer, on_event, on_raw_line)
          output = output_acc |> Enum.reverse() |> Enum.join() |> String.trim()
          events = Enum.reverse(Enum.reverse(trailing_events) ++ event_acc)
          _ = if trailing_any?, do: monotonic_ms(), else: last_event_ms
          {:ok, output, events}

        {:jido_shell_session, ^session_id, {:error, reason}} ->
          {:error, reason}

        {:jido_shell_session, ^session_id, :command_cancelled} ->
          {:error, :cancelled}

        {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
          {:error, {:command_crashed, reason}}

        {:jido_shell_session, ^session_id, _event} when not started? ->
          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )
      after
        min(heartbeat_interval_ms, remaining) ->
          idle_ms = monotonic_ms() - last_event_ms

          if idle_ms >= heartbeat_interval_ms do
            safe_callback(on_heartbeat, idle_ms)
          end

          collect_stream_output(
            session_id,
            deadline_ms,
            heartbeat_interval_ms,
            on_event,
            on_raw_line,
            on_heartbeat,
            line_buffer,
            output_acc,
            event_acc,
            started?,
            last_event_ms
          )
      end
    end
  end

  defp consume_stream_chunk(buffer, chunk, on_event, on_raw_line) do
    {next_buffer, lines} = split_complete_lines(buffer <> chunk)

    {events, parsed_any?} =
      Enum.reduce(lines, {[], false}, fn line, {acc, any?} ->
        case parse_stream_line(line) do
          {:event, event} ->
            safe_callback(on_event, event)
            {[event | acc], true}

          {:raw, raw_line} ->
            safe_callback(on_raw_line, raw_line)
            {acc, any?}

          :empty ->
            {acc, any?}
        end
      end)

    {next_buffer, Enum.reverse(events), parsed_any?}
  end

  defp parse_tail_buffer("", _on_event, _on_raw_line), do: {[], false}

  defp parse_tail_buffer(buffer, on_event, on_raw_line) do
    case parse_stream_line(buffer) do
      {:event, event} ->
        safe_callback(on_event, event)
        {[event], true}

      {:raw, raw_line} ->
        safe_callback(on_raw_line, raw_line)
        {[], false}

      :empty ->
        {[], false}
    end
  end

  defp parse_all_stream_lines(output, on_event, on_raw_line) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case parse_stream_line(line) do
        {:event, event} ->
          safe_callback(on_event, event)
          [event | acc]

        {:raw, raw_line} ->
          safe_callback(on_raw_line, raw_line)
          acc

        :empty ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp split_complete_lines(content) do
    lines = String.split(content, "\n", trim: false)

    case Enum.reverse(lines) do
      [tail | rev_complete] -> {tail, Enum.reverse(rev_complete)}
      [] -> {"", []}
    end
  end

  defp parse_stream_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :empty

      true ->
        case Jason.decode(trimmed) do
          {:ok, event} when is_map(event) -> {:event, event}
          _ -> {:raw, trimmed}
        end
    end
  end

  defp safe_callback(fun, value) when is_function(fun, 1) do
    _ = fun.(value)
    :ok
  rescue
    _ -> :ok
  end

  defp safe_callback(_fun, _value), do: :ok

  defp drain_shell_events(session_id) do
    receive do
      {:jido_shell_session, ^session_id, _event} ->
        drain_shell_events(session_id)
    after
      0 ->
        :ok
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
