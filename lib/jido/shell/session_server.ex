defmodule Jido.Shell.SessionServer do
  @moduledoc deprecated: "Use Jido.Shell.ShellSessionServer"

  @moduledoc """
  Deprecated compatibility shim for `Jido.Shell.ShellSessionServer`.

  This module will be removed in a future release.
  """

  alias Jido.Shell.Error
  alias Jido.Shell.ShellSessionServer

  @deprecated "Use Jido.Shell.ShellSessionServer.start_link/1"
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ShellSessionServer.start_link(opts)
  end

  @deprecated "Use Jido.Shell.ShellSessionServer.subscribe/3"
  @spec subscribe(String.t(), pid(), keyword()) :: {:ok, :subscribed} | {:error, Error.t()}
  def subscribe(session_id, transport_pid, opts \\ []) do
    ShellSessionServer.subscribe(session_id, transport_pid, opts)
  end

  @deprecated "Use Jido.Shell.ShellSessionServer.unsubscribe/2"
  @spec unsubscribe(String.t(), pid()) :: {:ok, :unsubscribed} | {:error, Error.t()}
  def unsubscribe(session_id, transport_pid) do
    ShellSessionServer.unsubscribe(session_id, transport_pid)
  end

  @deprecated "Use Jido.Shell.ShellSessionServer.get_state/1"
  @spec get_state(String.t()) :: {:ok, Jido.Shell.ShellSession.State.t()} | {:error, Error.t()}
  def get_state(session_id) do
    ShellSessionServer.get_state(session_id)
  end

  @deprecated "Use Jido.Shell.ShellSessionServer.run_command/3"
  @spec run_command(String.t(), String.t(), keyword()) :: {:ok, :accepted} | {:error, Error.t()}
  def run_command(session_id, line, opts \\ []) do
    ShellSessionServer.run_command(session_id, line, opts)
  end

  @deprecated "Use Jido.Shell.ShellSessionServer.cancel/1"
  @spec cancel(String.t()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(session_id) do
    ShellSessionServer.cancel(session_id)
  end
end
