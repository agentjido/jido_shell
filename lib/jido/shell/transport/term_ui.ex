defmodule Jido.Shell.Transport.TermUI do
  @moduledoc """
  Rich terminal UI transport for Kodo sessions.

  Provides a full-screen terminal interface with:
  - Header showing session info and cwd
  - Scrollable output area
  - Input line with history navigation

  ## Usage

      iex> Jido.Shell.Transport.TermUI.start(:my_workspace)

  This is a simplified MVU-style implementation that can be
  enhanced with the term_ui library for more features.
  """

  alias Jido.Shell.Session
  alias Jido.Shell.SessionServer

  @type model :: %{
          session_id: String.t(),
          workspace_id: atom(),
          cwd: String.t(),
          output_buffer: [String.t()],
          input: String.t(),
          history: [String.t()],
          history_index: integer(),
          command_running: boolean(),
          scroll_offset: integer()
        }

  @doc """
  Starts the TermUI for a workspace.
  """
  @spec start(atom(), keyword()) :: :ok
  def start(workspace_id, opts \\ []) when is_atom(workspace_id) do
    {:ok, session_id} = Session.start_with_vfs(workspace_id, opts)

    :ok = SessionServer.subscribe(session_id, self())

    {:ok, state} = SessionServer.get_state(session_id)

    model = %{
      session_id: session_id,
      workspace_id: workspace_id,
      cwd: state.cwd,
      output_buffer: [],
      input: "",
      history: [],
      history_index: 0,
      command_running: false,
      scroll_offset: 0
    }

    run(model)
  end

  @doc """
  Attaches to an existing session.
  """
  @spec attach(String.t()) :: :ok | {:error, :not_found}
  def attach(session_id) do
    case Session.lookup(session_id) do
      {:ok, _pid} ->
        :ok = SessionServer.subscribe(session_id, self())
        {:ok, state} = SessionServer.get_state(session_id)

        model = %{
          session_id: session_id,
          workspace_id: state.workspace_id,
          cwd: state.cwd,
          output_buffer: [],
          input: "",
          history: state.history,
          history_index: 0,
          command_running: state.current_command != nil,
          scroll_offset: 0
        }

        run(model)

      {:error, :not_found} = error ->
        error
    end
  end

  # === MVU Loop ===

  defp run(model) do
    clear_screen()
    render(model)

    case wait_for_input() do
      {:key, :ctrl_c} when model.command_running ->
        SessionServer.cancel(model.session_id)
        run(model)

      {:key, :ctrl_c} ->
        clear_screen()
        IO.puts("Goodbye!")
        :ok

      {:key, :ctrl_d} ->
        clear_screen()
        IO.puts("Goodbye!")
        :ok

      {:key, :enter} ->
        model = handle_enter(model)
        run(model)

      {:key, :backspace} ->
        model = %{model | input: String.slice(model.input, 0..-2//1)}
        run(model)

      {:key, :up} ->
        model = history_up(model)
        run(model)

      {:key, :down} ->
        model = history_down(model)
        run(model)

      {:key, {:char, c}} ->
        model = %{model | input: model.input <> <<c>>}
        run(model)

      {:session_event, event} ->
        model = handle_session_event(model, event)
        run(model)

      :timeout ->
        run(model)

      _ ->
        run(model)
    end
  catch
    :exit -> :ok
  end

  # === Input Handling ===

  defp wait_for_input do
    receive do
      {:jido_shell_session, _session_id, event} ->
        {:session_event, event}
    after
      100 ->
        case IO.getn("", 1) do
          "\e" ->
            read_escape_sequence()

          "\r" ->
            {:key, :enter}

          "\n" ->
            {:key, :enter}

          <<127>> ->
            {:key, :backspace}

          <<3>> ->
            {:key, :ctrl_c}

          <<4>> ->
            {:key, :ctrl_d}

          c when is_binary(c) and byte_size(c) == 1 ->
            <<char>> = c
            {:key, {:char, char}}

          _ ->
            :timeout
        end
    end
  end

  defp read_escape_sequence do
    case IO.getn("", 1) do
      "[" ->
        case IO.getn("", 1) do
          "A" -> {:key, :up}
          "B" -> {:key, :down}
          "C" -> {:key, :right}
          "D" -> {:key, :left}
          _ -> {:key, :escape}
        end

      _ ->
        {:key, :escape}
    end
  end

  defp handle_enter(%{input: ""} = model), do: model

  defp handle_enter(%{input: "exit"}) do
    clear_screen()
    IO.puts("Goodbye!")
    throw(:exit)
  end

  defp handle_enter(%{input: "quit"}) do
    clear_screen()
    IO.puts("Goodbye!")
    throw(:exit)
  end

  defp handle_enter(model) do
    :ok = SessionServer.run_command(model.session_id, model.input)

    %{
      model
      | history: [model.input | model.history],
        history_index: 0,
        input: "",
        command_running: true
    }
  end

  defp history_up(%{history: []} = model), do: model

  defp history_up(%{history: history, history_index: idx} = model) do
    new_idx = min(idx + 1, length(history))
    input = Enum.at(history, new_idx - 1) || model.input
    %{model | history_index: new_idx, input: input}
  end

  defp history_down(%{history_index: 0} = model), do: model

  defp history_down(%{history: history, history_index: idx} = model) do
    new_idx = max(idx - 1, 0)
    input = if new_idx == 0, do: "", else: Enum.at(history, new_idx - 1) || ""
    %{model | history_index: new_idx, input: input}
  end

  # === Session Events ===

  defp handle_session_event(model, {:command_started, _line}) do
    model
  end

  defp handle_session_event(model, {:output, chunk}) do
    %{model | output_buffer: model.output_buffer ++ [chunk]}
  end

  defp handle_session_event(model, {:error, error}) do
    error_line = "\e[31mError: #{error.message}\e[0m\n"

    %{
      model
      | output_buffer: model.output_buffer ++ [error_line],
        command_running: false
    }
  end

  defp handle_session_event(model, {:cwd_changed, cwd}) do
    %{model | cwd: cwd}
  end

  defp handle_session_event(model, :command_done) do
    %{model | command_running: false}
  end

  defp handle_session_event(model, :command_cancelled) do
    %{
      model
      | output_buffer: model.output_buffer ++ ["\e[33mCancelled\e[0m\n"],
        command_running: false
    }
  end

  defp handle_session_event(model, {:command_crashed, reason}) do
    error_line = "\e[31mCrashed: #{inspect(reason)}\e[0m\n"

    %{
      model
      | output_buffer: model.output_buffer ++ [error_line],
        command_running: false
    }
  end

  defp handle_session_event(model, _event), do: model

  # === Rendering ===

  defp clear_screen do
    IO.write("\e[2J\e[H")
  end

  defp render(model) do
    {width, height} = get_terminal_size()

    header = render_header(model, width)

    output_height = height - 4

    output = render_output(model, width, output_height)

    status = render_status(model, width)

    input_line = render_input(model)

    IO.write("\e[H")
    IO.write(header)
    IO.write(output)
    IO.write(status)
    IO.write(input_line)

    cursor_col = String.length(model.cwd) + String.length(model.input) + 3
    IO.write("\e[#{height};#{cursor_col}H")
  end

  defp render_header(model, width) do
    title = "Kodo Shell - #{model.workspace_id}"
    cwd_line = "cwd: #{model.cwd}"

    "\e[7m" <>
      String.pad_trailing(title, width) <>
      "\e[0m\n" <>
      "\e[36m#{cwd_line}\e[0m\n"
  end

  defp render_output(model, _width, height) do
    all_output = Enum.join(model.output_buffer)
    lines = String.split(all_output, "\n", trim: false)

    visible_lines = Enum.take(lines, -height)

    padding = height - length(visible_lines)
    padded = List.duplicate("\n", padding) ++ Enum.map(visible_lines, &(&1 <> "\n"))

    Enum.join(padded)
  end

  defp render_status(model, width) do
    status =
      if model.command_running do
        "\e[33m[Running...]\e[0m"
      else
        "\e[32m[Ready]\e[0m"
      end

    String.pad_trailing(status, width) <> "\n"
  end

  defp render_input(model) do
    prompt = "\e[36m#{model.cwd}\e[0m> "
    prompt <> model.input
  end

  defp get_terminal_size do
    case :io.columns() do
      {:ok, cols} ->
        rows =
          case :io.rows() do
            {:ok, r} -> r
            _ -> 24
          end

        {cols, rows}

      _ ->
        {80, 24}
    end
  end
end
