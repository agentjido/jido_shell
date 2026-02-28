defmodule Jido.Shell.Backend.SSH.KeyCallback do
  @moduledoc false

  # Custom SSH key callback for injecting PEM key content directly
  # rather than reading from the default ~/.ssh/ directory.
  #
  # Supports standard PEM formats (RSA, ECDSA) and OpenSSH-format
  # Ed25519 keys (-----BEGIN OPENSSH PRIVATE KEY-----).

  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(_key, _host, _port, _algorithm, _opts) do
    true
  end

  @impl true
  def user_key(algorithm, opts) do
    # OTP 23+ passes key_cb tuple options under :key_cb_private
    key_pem = get_key_from_opts(opts)

    case :public_key.pem_decode(key_pem) do
      [] ->
        {:error, :no_keys_found}

      [{{:no_asn1, :new_openssh}, _der, :not_encrypted} | _] ->
        # OpenSSH-format key (e.g. Ed25519) — use :ssh_file to decode
        decode_openssh_key(key_pem, algorithm)

      entries ->
        find_key_for_algorithm(entries, algorithm)
    end
  end

  defp decode_openssh_key(key_pem, algorithm) do
    case :ssh_file.decode(key_pem, :openssh_key_v1) do
      [{key, _attrs} | _] when is_tuple(key) ->
        if key_matches_algorithm?(key, algorithm) do
          {:ok, key}
        else
          {:error, :no_matching_key}
        end

      _ ->
        {:error, :openssh_decode_failed}
    end
  rescue
    _ -> {:error, :openssh_decode_failed}
  end

  defp find_key_for_algorithm(entries, algorithm) do
    Enum.find_value(entries, {:error, :no_matching_key}, fn entry ->
      case :public_key.pem_entry_decode(entry) do
        key when is_tuple(key) ->
          if key_matches_algorithm?(key, algorithm) do
            {:ok, key}
          else
            nil
          end

        _ ->
          nil
      end
    end)
  rescue
    _ -> {:error, :key_decode_failed}
  end

  defp key_matches_algorithm?(key, algorithm) do
    case {elem(key, 0), algorithm} do
      {:RSAPrivateKey, :"ssh-rsa"} -> true
      {:ECPrivateKey, :"ecdsa-sha2-nistp256"} -> true
      {:ECPrivateKey, :"ecdsa-sha2-nistp384"} -> true
      {:ECPrivateKey, :"ecdsa-sha2-nistp521"} -> true
      # OTP wraps Ed25519 as ECPrivateKey with namedCurve {1,3,101,112}
      {:ECPrivateKey, :"ssh-ed25519"} -> ed25519_curve?(key)
      {:ECPrivateKey, :"ssh-ed448"} -> ed448_curve?(key)
      # OTP may also use these representations
      _ when algorithm in [:"ssh-ed25519", :"ssh-ed448"] -> is_ed_key?(key)
      _ -> false
    end
  end

  defp ed25519_curve?({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _, _}), do: true
  defp ed25519_curve?({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _}), do: true
  defp ed25519_curve?(_), do: false

  defp ed448_curve?({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 113}}, _, _}), do: true
  defp ed448_curve?({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 113}}, _}), do: true
  defp ed448_curve?(_), do: false

  defp is_ed_key?(key) when is_map(key), do: true
  defp is_ed_key?({:ed_pri, _, _, _}), do: true
  defp is_ed_key?(_), do: false

  defp get_key_from_opts(opts) do
    case opts[:key_cb_private] do
      private when is_list(private) -> Keyword.get(private, :key)
      _ -> nil
    end || opts[:key]
  end
end
