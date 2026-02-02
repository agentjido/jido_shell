defmodule Kodo.Transport.TermUI do
  @moduledoc """
  Rich terminal UI transport for Kodo sessions using the term_ui library.

  Provides a full-screen terminal interface with:
  - Header showing session info and cwd
  - Scrollable output area
  - Input line with history navigation

  ## Usage

      iex> Kodo.Transport.TermUI.start(:my_workspace)

  Press Ctrl+C or type "exit" to quit.
  """

  use TermUI.Elm

  alias Kodo.Session
  alias Kodo.SessionServer
  alias TermUI.Event
  alias TermUI.Renderer.Style

  defstruct [
    :session_id,
    :workspace_id,
    :cwd,
    output_lines: [],
    input: "",
    history: [],
    history_index: 0,
    command_running: false
  ]

  @doc """
  Starts the TermUI for a workspace.
  """
  @spec start(atom(), keyword()) :: :ok | {:error, term()}
  def start(workspace_id, opts \\ []) when is_atom(workspace_id) do
    case Session.start_with_vfs(workspace_id, opts) do
      {:ok, session_id} ->
        run_with_session(session_id, workspace_id)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Attaches to an existing session.
  """
  @spec attach(String.t()) :: :ok | {:error, :not_found}
  def attach(session_id) do
    case Session.lookup(session_id) do
      {:ok, _pid} ->
        {:ok, state} = SessionServer.get_state(session_id)
        run_with_session(session_id, state.workspace_id)

      {:error, :not_found} = error ->
        error
    end
  end

  defp run_with_session(session_id, workspace_id) do
    # Start runtime (non-blocking) so we can get its PID for event forwarding
    {:ok, runtime} =
      TermUI.Runtime.start_link(
        root: __MODULE__,
        root_opts: [session_id: session_id, workspace_id: workspace_id]
      )

    # Subscribe to session events in this process
    :ok = SessionServer.subscribe(session_id, self())

    # Monitor runtime and forward events until it exits
    ref = Process.monitor(runtime)
    forward_events_loop(runtime, session_id, ref)
  end

  defp forward_events_loop(runtime, session_id, ref) do
    receive do
      {:kodo_session, ^session_id, event} ->
        # Use send_message to deliver directly to the :root component
        TermUI.Runtime.send_message(runtime, :root, {:session, event})
        forward_events_loop(runtime, session_id, ref)

      {:DOWN, ^ref, :process, ^runtime, _reason} ->
        :ok
    after
      60_000 ->
        forward_events_loop(runtime, session_id, ref)
    end
  end

  # === Elm Architecture Callbacks ===

  @impl true
  def init(opts) do
    # TermUI passes the full opts, root_opts contains our session info
    root_opts = Keyword.get(opts, :root_opts, opts)
    session_id = Keyword.fetch!(root_opts, :session_id)
    workspace_id = Keyword.fetch!(root_opts, :workspace_id)

    {:ok, session_state} = SessionServer.get_state(session_id)

    %__MODULE__{
      session_id: session_id,
      workspace_id: workspace_id,
      cwd: session_state.cwd,
      history: session_state.history
    }
  end

  @impl true
  def event_to_msg(%Event.Key{key: "c", modifiers: [:ctrl]}, %{command_running: true}), do: {:msg, :cancel}
  def event_to_msg(%Event.Key{key: "c", modifiers: [:ctrl]}, _state), do: {:msg, :quit}
  def event_to_msg(%Event.Key{key: "d", modifiers: [:ctrl]}, _state), do: {:msg, :quit}
  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :history_up}
  def event_to_msg(%Event.Key{key: :down}, _state), do: {:msg, :history_down}
  def event_to_msg(%Event.Key{key: char}, _state) when is_binary(char), do: {:msg, {:char, char}}
  # Note: Session events come via send_message, not events
  def event_to_msg(_, _), do: :ignore

  @impl true
  def update(:quit, state), do: {state, [:quit]}

  def update(:cancel, state) do
    SessionServer.cancel(state.session_id)
    {state, []}
  end

  def update(:submit, %{input: ""} = state), do: {state, []}

  def update(:submit, %{input: "exit"} = state), do: {state, [:quit]}
  def update(:submit, %{input: "quit"} = state), do: {state, [:quit]}

  def update(:submit, state) do
    :ok = SessionServer.run_command(state.session_id, state.input)

    new_state = %{
      state
      | history: [state.input | state.history],
        history_index: 0,
        input: "",
        command_running: true
    }

    {new_state, []}
  end

  def update(:backspace, state) do
    {%{state | input: String.slice(state.input, 0..-2//1)}, []}
  end

  def update(:history_up, %{history: []} = state), do: {state, []}

  def update(:history_up, state) do
    new_idx = min(state.history_index + 1, length(state.history))
    input = Enum.at(state.history, new_idx - 1) || state.input
    {%{state | history_index: new_idx, input: input}, []}
  end

  def update(:history_down, %{history_index: 0} = state), do: {state, []}

  def update(:history_down, state) do
    new_idx = max(state.history_index - 1, 0)
    input = if new_idx == 0, do: "", else: Enum.at(state.history, new_idx - 1) || ""
    {%{state | history_index: new_idx, input: input}, []}
  end

  def update({:char, char}, state) do
    {%{state | input: state.input <> char}, []}
  end

  def update({:session, event}, state) do
    {handle_session_event(state, event), []}
  end

  # === Session Event Handlers ===

  defp handle_session_event(state, {:command_started, _line}), do: state

  defp handle_session_event(state, {:output, chunk}) do
    # Strip ANSI escape sequences since TermUI handles styling separately
    clean_chunk = strip_ansi(chunk)
    new_lines = String.split(clean_chunk, "\n", trim: false)
    %{state | output_lines: state.output_lines ++ new_lines}
  end

  defp handle_session_event(state, {:error, error}) do
    %{state | output_lines: state.output_lines ++ ["Error: #{error.message}"], command_running: false}
  end

  defp handle_session_event(state, {:cwd_changed, cwd}) do
    %{state | cwd: cwd}
  end

  defp handle_session_event(state, :command_done) do
    %{state | command_running: false}
  end

  defp handle_session_event(state, :command_cancelled) do
    %{state | output_lines: state.output_lines ++ ["Cancelled"], command_running: false}
  end

  defp handle_session_event(state, {:command_crashed, reason}) do
    %{state | output_lines: state.output_lines ++ ["Crashed: #{inspect(reason)}"], command_running: false}
  end

  defp handle_session_event(state, _event), do: state

  # === View ===

  @impl true
  def view(state) do
    stack(:vertical, [
      render_header(state),
      render_output(state),
      render_status(state),
      render_input(state)
    ])
  end

  defp render_header(state) do
    stack(:vertical, [
      text("Kodo Shell - #{state.workspace_id}", Style.new(fg: :white, bg: :blue, attrs: [:bold])),
      text("cwd: #{state.cwd}", Style.new(fg: :cyan))
    ])
  end

  defp render_output(state) do
    lines =
      state.output_lines
      |> Enum.take(-20)
      |> Enum.map(&text(&1, nil))

    if Enum.empty?(lines) do
      text("", nil)
    else
      stack(:vertical, lines)
    end
  end

  defp render_status(state) do
    if state.command_running do
      text("[Running...]", Style.new(fg: :yellow))
    else
      text("[Ready]", Style.new(fg: :green))
    end
  end

  defp render_input(state) do
    prompt = "#{state.cwd}> "
    text(prompt <> state.input, Style.new(fg: :cyan))
  end

  # === Helpers ===

  # Strip ANSI escape sequences from output
  defp strip_ansi(text) do
    # Match CSI sequences (ESC[...m and similar) and OSC sequences
    text
    |> String.replace(~r/\e\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\][^\a]*\a/, "")
  end
end
