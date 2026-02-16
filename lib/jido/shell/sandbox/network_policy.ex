defmodule Jido.Shell.Sandbox.NetworkPolicy do
  @moduledoc """
  Network permission checks for sandboxed script execution.

  Policy is configured per execution context under `:network`, supporting:
  - `:default` (`:deny` or `:allow`, default `:deny`)
  - `:allow_domains` (list of domains)
  - `:block_domains` (list of domains)
  - `:allow_ports` (list of ports)
  - `:block_ports` (list of ports)
  """

  alias Jido.Shell.Command.Parser
  alias Jido.Shell.Error

  @network_commands ~w(curl wget nc ncat telnet ssh scp sftp ftp ping dig nslookup)
  @url_regex ~r/https?:\/\/([A-Za-z0-9\.\-]+)(?::(\d{1,5}))?/
  @host_port_regex ~r/\b([A-Za-z0-9\.\-]+):(\d{1,5})\b/
  @bracketed_host_port_regex ~r/\[([A-Fa-f0-9:]+)\]:(\d{1,5})/
  @port_flag_regex ~r/^--port=(\d{1,5})$/
  @port_short_flag_regex ~r/^-p(\d{1,5})$/
  @domain_like_regex ~r/^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$/
  @ipv4_regex ~r/^\d{1,3}(?:\.\d{1,3}){3}$/

  @type policy_context :: map() | keyword()

  @doc """
  Enforces network policy for a script statement.
  """
  @spec enforce(String.t(), policy_context()) :: :ok | {:error, Error.t()}
  def enforce(line, execution_context) when is_binary(line) do
    case Parser.parse_program(line) do
      {:ok, commands} ->
        policy = normalize_policy(execution_context)
        enforce_commands(line, commands, policy)

      _ ->
        :ok
    end
  end

  defp enforce_commands(_line, [], _policy), do: :ok

  defp enforce_commands(line, [%{command: command, args: args} | rest], policy) do
    if network_command?(command) do
      case check_network_command(line, command, args, policy) do
        :ok -> enforce_commands(line, rest, policy)
        {:error, _} = error -> error
      end
    else
      enforce_commands(line, rest, policy)
    end
  end

  defp check_network_command(line, command, args, policy) do
    endpoints = extract_endpoints(args)

    with :ok <- check_blocklists(line, command, endpoints, policy),
         :ok <- check_allowlists(line, command, endpoints, policy),
         :ok <- check_default(line, command, policy) do
      :ok
    end
  end

  defp check_blocklists(line, command, endpoints, policy) do
    blocked_domain = Enum.find(endpoints.domains, &MapSet.member?(policy.block_domains, &1))
    blocked_port = Enum.find(endpoints.ports, &MapSet.member?(policy.block_ports, &1))

    cond do
      blocked_domain ->
        blocked_error(
          line,
          command,
          "network access blocked: domain '#{blocked_domain}' is blocklisted",
          %{domain: blocked_domain}
        )

      blocked_port ->
        blocked_error(
          line,
          command,
          "network access blocked: port #{blocked_port} is blocklisted",
          %{port: blocked_port}
        )

      true ->
        :ok
    end
  end

  defp check_allowlists(line, command, endpoints, policy) do
    cond do
      MapSet.size(policy.allow_domains) > 0 and endpoints.domains == [] ->
        blocked_error(
          line,
          command,
          "network access blocked: unable to determine target domain for allowlist check"
        )

      MapSet.size(policy.allow_ports) > 0 and endpoints.ports == [] ->
        blocked_error(
          line,
          command,
          "network access blocked: unable to determine target port for allowlist check"
        )

      true ->
        check_allow_membership(line, command, endpoints, policy)
    end
  end

  defp check_allow_membership(line, command, endpoints, policy) do
    disallowed_domain =
      if MapSet.size(policy.allow_domains) == 0 do
        nil
      else
        Enum.find(endpoints.domains, &(not MapSet.member?(policy.allow_domains, &1)))
      end

    disallowed_port =
      if MapSet.size(policy.allow_ports) == 0 do
        nil
      else
        Enum.find(endpoints.ports, &(not MapSet.member?(policy.allow_ports, &1)))
      end

    cond do
      disallowed_domain ->
        blocked_error(
          line,
          command,
          "network access blocked: domain '#{disallowed_domain}' is not allowlisted",
          %{domain: disallowed_domain}
        )

      disallowed_port ->
        blocked_error(
          line,
          command,
          "network access blocked: port #{disallowed_port} is not allowlisted",
          %{port: disallowed_port}
        )

      true ->
        :ok
    end
  end

  defp check_default(line, command, policy) do
    if policy.default == :deny and MapSet.size(policy.allow_domains) == 0 and MapSet.size(policy.allow_ports) == 0 do
      blocked_error(
        line,
        command,
        "network access blocked: sandbox network is denied by default; configure execution_context.network allowlists to permit access"
      )
    else
      :ok
    end
  end

  defp blocked_error(line, command, message, extra \\ %{}) do
    {:error,
     %Error{
       code: {:shell, :network_blocked},
       message: message,
       context:
         extra
         |> Map.put(:line, line)
         |> Map.put(:command, command)
     }}
  end

  defp normalize_policy(execution_context) do
    network = get_opt(execution_context, :network, %{})

    %{
      default: normalize_default(get_opt(network, :default, :deny)),
      allow_domains: normalize_domains(get_opt(network, :allow_domains, [])),
      block_domains: normalize_domains(get_opt(network, :block_domains, [])),
      allow_ports: normalize_ports(get_opt(network, :allow_ports, [])),
      block_ports: normalize_ports(get_opt(network, :block_ports, []))
    }
  end

  defp normalize_default(:allow), do: :allow
  defp normalize_default("allow"), do: :allow
  defp normalize_default(_), do: :deny

  defp normalize_domains(domains) do
    domains
    |> List.wrap()
    |> Enum.map(&String.trim(String.downcase(to_string(&1))))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_ports(ports) do
    ports
    |> List.wrap()
    |> Enum.reduce(MapSet.new(), fn port, acc ->
      case to_port(port) do
        nil -> acc
        parsed -> MapSet.put(acc, parsed)
      end
    end)
  end

  defp to_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: port

  defp to_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed >= 0 and parsed <= 65_535 -> parsed
      _ -> nil
    end
  end

  defp to_port(_), do: nil

  defp extract_endpoints(args) do
    args
    |> Enum.with_index()
    |> Enum.reduce(%{domains: [], ports: []}, fn {arg, idx}, acc ->
      next_arg = Enum.at(args, idx + 1)

      acc
      |> extract_from_url(arg)
      |> extract_from_host_port(arg)
      |> extract_from_bracketed_host_port(arg)
      |> extract_from_port_flags(arg, next_arg)
      |> extract_from_bare_host(arg)
    end)
    |> Map.update!(:domains, &Enum.uniq/1)
    |> Map.update!(:ports, &Enum.uniq/1)
  end

  defp extract_from_url(acc, arg) do
    Regex.scan(@url_regex, arg)
    |> Enum.reduce(acc, fn
      [_, domain, port], current ->
        current
        |> add_domain(domain)
        |> maybe_add_port(port)

      [_, domain], current ->
        add_domain(current, domain)

      _other, current ->
        current
    end)
  end

  defp extract_from_host_port(acc, arg) do
    if String.contains?(arg, "[") do
      acc
    else
      Regex.scan(@host_port_regex, arg)
      |> Enum.reduce(acc, fn
        [_, domain, port], current ->
          current
          |> add_domain(domain)
          |> maybe_add_port(port)

        _other, current ->
          current
      end)
    end
  end

  defp extract_from_bracketed_host_port(acc, arg) do
    Regex.scan(@bracketed_host_port_regex, arg)
    |> Enum.reduce(acc, fn
      [_, host, port], current ->
        current
        |> add_domain(host)
        |> maybe_add_port(port)

      _other, current ->
        current
    end)
  end

  defp extract_from_port_flags(acc, arg, next_arg) do
    cond do
      Regex.match?(@port_flag_regex, arg) ->
        [_, port] = Regex.run(@port_flag_regex, arg)
        maybe_add_port(acc, port)

      Regex.match?(@port_short_flag_regex, arg) ->
        [_, port] = Regex.run(@port_short_flag_regex, arg)
        maybe_add_port(acc, port)

      arg == "-p" ->
        maybe_add_port(acc, next_arg)

      true ->
        acc
    end
  end

  defp extract_from_bare_host(acc, arg) do
    normalized =
      arg
      |> to_string()
      |> String.trim()
      |> String.trim_trailing(",")
      |> String.trim_trailing(";")

    cond do
      normalized == "" or String.starts_with?(normalized, "-") ->
        acc

      String.contains?(normalized, "://") ->
        acc

      String.starts_with?(normalized, "[") ->
        acc

      true ->
        host_part = normalized |> String.split("/", parts: 2) |> hd()

        case String.split(host_part, ":", parts: 2) do
          [host, port] when host != "" ->
            acc
            |> add_domain(host)
            |> maybe_add_port(port)

          [host] ->
            if Regex.match?(@domain_like_regex, host) or Regex.match?(@ipv4_regex, host) do
              add_domain(acc, host)
            else
              acc
            end

          _ ->
            acc
        end
    end
  end

  defp add_domain(acc, domain) do
    normalized = String.trim(String.downcase(domain))

    if normalized == "" do
      acc
    else
      Map.update!(acc, :domains, &[normalized | &1])
    end
  end

  defp maybe_add_port(acc, nil), do: acc
  defp maybe_add_port(acc, ""), do: acc

  defp maybe_add_port(acc, port) do
    case to_port(port) do
      nil -> acc
      parsed -> Map.update!(acc, :ports, &[parsed | &1])
    end
  end

  defp network_command?(command), do: command in @network_commands

  defp get_opt(data, key, default) when is_map(data) do
    Map.get(data, key, Map.get(data, Atom.to_string(key), default))
  end

  defp get_opt(data, key, default) when is_list(data) do
    if Keyword.keyword?(data) do
      Keyword.get(data, key, default)
    else
      default
    end
  end

  defp get_opt(_, _, default), do: default
end
