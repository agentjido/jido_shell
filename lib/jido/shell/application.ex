defmodule Jido.Shell.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Jido.Shell.VFS.init()

    children = [
      {Registry, keys: :unique, name: Jido.Shell.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Shell.SessionSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.Shell.FilesystemSupervisor},
      {Task.Supervisor, name: Jido.Shell.CommandTaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Jido.Shell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
