defmodule Jido.Shell.Session.State do
  @moduledoc deprecated: "Use Jido.Shell.ShellSession.State"

  @moduledoc """
  Deprecated compatibility shim for `Jido.Shell.ShellSession.State`.

  This module will be removed in a future release.
  Note: state struct identity is now `%Jido.Shell.ShellSession.State{}`.
  """

  alias Jido.Shell.ShellSession.State, as: ShellState

  @type t :: ShellState.t()

  @deprecated "Use Jido.Shell.ShellSession.State.schema/0"
  @spec schema() :: term()
  defdelegate schema(), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.new/1"
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  defdelegate new(attrs), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.new!/1"
  @spec new!(map()) :: t()
  defdelegate new!(attrs), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.add_transport/2"
  @spec add_transport(t(), pid()) :: t()
  defdelegate add_transport(state, pid), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.remove_transport/2"
  @spec remove_transport(t(), pid()) :: t()
  defdelegate remove_transport(state, pid), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.add_to_history/2"
  @spec add_to_history(t(), String.t()) :: t()
  defdelegate add_to_history(state, line), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.set_cwd/2"
  @spec set_cwd(t(), String.t()) :: t()
  defdelegate set_cwd(state, cwd), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.set_current_command/2"
  @spec set_current_command(t(), map() | nil) :: t()
  defdelegate set_current_command(state, command), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.clear_current_command/1"
  @spec clear_current_command(t()) :: t()
  defdelegate clear_current_command(state), to: ShellState

  @deprecated "Use Jido.Shell.ShellSession.State.command_running?/1"
  @spec command_running?(t()) :: boolean()
  defdelegate command_running?(state), to: ShellState
end
