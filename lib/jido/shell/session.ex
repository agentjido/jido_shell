defmodule Jido.Shell.Session do
  @moduledoc deprecated: "Use Jido.Shell.ShellSession"

  @moduledoc """
  Deprecated compatibility shim for `Jido.Shell.ShellSession`.

  This module will be removed in a future release.
  """

  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession

  @type workspace_id :: String.t()

  @deprecated "Use Jido.Shell.ShellSession.start/2"
  @spec start(workspace_id() | term(), keyword()) :: {:ok, String.t()} | {:error, Error.t() | term()}
  def start(workspace_id, opts \\ []) do
    ShellSession.start(workspace_id, opts)
  end

  @deprecated "Use Jido.Shell.ShellSession.stop/1"
  @spec stop(String.t()) :: :ok | {:error, :not_found | term()}
  def stop(session_id) do
    ShellSession.stop(session_id)
  end

  @deprecated "Use Jido.Shell.ShellSession.generate_id/0"
  @spec generate_id() :: String.t()
  def generate_id do
    ShellSession.generate_id()
  end

  @deprecated "Use Jido.Shell.ShellSession.via_registry/1"
  @spec via_registry(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_registry(session_id) do
    ShellSession.via_registry(session_id)
  end

  @deprecated "Use Jido.Shell.ShellSession.lookup/1"
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) do
    ShellSession.lookup(session_id)
  end

  @deprecated "Use Jido.Shell.ShellSession.start_with_vfs/2"
  @spec start_with_vfs(workspace_id(), keyword()) :: {:ok, String.t()} | {:error, Error.t() | term()}
  def start_with_vfs(workspace_id, opts \\ []) do
    ShellSession.start_with_vfs(workspace_id, opts)
  end

  @deprecated "Use Jido.Shell.ShellSession.teardown_workspace/2"
  @spec teardown_workspace(workspace_id(), keyword()) :: :ok | {:error, Error.t()}
  def teardown_workspace(workspace_id, opts \\ []) do
    ShellSession.teardown_workspace(workspace_id, opts)
  end
end
