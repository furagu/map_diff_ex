defmodule MapDiffEx do
  require MinifiedListDiff

  @default_minify_threshold 500

  def diff(map1, map2, options \\ %{}), do: do_diff(map1, map2, options)

  defp do_diff(map1, map2, _options) when map1 == map2, do: nil
  defp do_diff(map1, map2, options) when is_map(map1) and is_map(map2) do
    ignore_keys = options[:ignore] || []
    key_not_set_marker = options[:key_not_set_marker] || :key_not_set
    Dict.keys(map1) ++ Dict.keys(map2)
    |> Enum.uniq
    |> Enum.map(fn key ->
      cond do
        Enum.member?(ignore_keys, key |> Atom.to_string) ->
          {key, nil}
        true ->
          value1 = Dict.get(map1, key, key_not_set_marker)
          value2 = Dict.get(map2, key, key_not_set_marker)
          next_level_options = Dict.put(options, :ignore, ignore_keys |> strip_prefix_from_string_list(key))

          { key, do_diff(value1, value2, next_level_options) }
      end
    end)
    |> filter_nil_values
    |> to_map
    |> filter_empty_map
  end
  defp do_diff(list1, list2, options) when is_list(list1) and is_list(list2) do
    case length(list1) == length(list2) do
      false -> compare_differing_size_lists(list1, list2, options)
      true  -> compare_same_size_lists(list1, list2, options)
    end
  end
  defp do_diff(value1, value2, options) do
    same_defs = Dict.get(options, :treat_as_same, [])
    accuracy = Dict.get(options, :float_accuracy, nil)
    cond do
      similar_value?(value1, value2, same_defs)      -> nil
      only_diff_in_whitespaces(value1, value2)         -> nil
      similar_float_binaries(value1, value2, accuracy) -> nil
      true                                             -> {value1, value2}
    end
  end

  def strip_prefix_from_string_list(ignore_keys, key) do
    ignore_keys
    |> Enum.map(fn key_to_ignore ->
      prefix = "#{key}."
      cond do
        String.starts_with?(key_to_ignore, prefix) ->
          String.slice(key_to_ignore, String.length(prefix)..-1)
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil(&1))
  end

  defp compare_differing_size_lists(list1, list2, options) do
    checksums1 = list_of_checksums(list1)
    checksums2 = list_of_checksums(list2)

    # list of big documents can't be really compared, so we try to optimize for that
    threshold = options[:minify_threshold] || @default_minify_threshold
    minify = max(String.length(inspect(list1)), String.length(inspect(list2))) > threshold
    case {minify, MinifiedListDiff.diff(checksums1, checksums2)} do
      {_, nil}   -> {list1, list2}
      {false, _} -> {list1, list2}
      {true, {:right, index, _}} ->
        elem = Enum.at(list2, index)
        {"#{length(list1)} element List", {"List with additional element", elem}}
      {true, {:left, index, _}} ->
        elem = Enum.at(list1, index)
        {{"List with additional element", elem}, "#{length(list2)} element List"}
    end
  end

  defp compare_same_size_lists(list1, list2, options) do
    checksums1 = list_of_checksums(list1)
    checksums2 = list_of_checksums(list2)

    ignore_list_order = Dict.get(options, :ignore_list_order, false)
    cond do
      checksums1 == checksums2 ->
        nil
      same_elements?(checksums1, checksums2) && ignore_list_order ->
        nil
      same_elements?(checksums1, checksums2) && !ignore_list_order ->
        order_diff(checksums1, checksums2)
      true ->
        list1 = if ignore_list_order, do: Enum.sort(list1), else: list1
        list2 = if ignore_list_order, do: Enum.sort(list2), else: list2

        (0..length(list1)-1)
        |> Enum.map(fn(i) ->
          do_diff(Enum.at(list1, i), Enum.at(list2, i), options)
        end)
        |> Enum.reject(&is_nil(&1))
        |> filter_empty_list
    end
  end

  defp same_elements?(list1, list2) do
    Enum.sort(list1) == Enum.sort(list2)
  end

  defp order_diff(list1, list2) when length(list1) == length(list2) do
    left_order = (0..length(list1)-1) |> Enum.join(",")
    right_order = list1 |> Enum.map(&Enum.find_index(list2, fn(x) -> x == &1 end)) |> Enum.join(",")

    {"List with order: #{left_order}", "List with order: #{right_order}"}
  end

  defp similar_value?(value1, value2, same_defs) do
    Enum.any?(same_defs, fn same_def ->
      if is_function same_def do
        try do
          same_def.(value1, value2)
        rescue _
          -> false
        end
      else
        {left, right} = if (is_list same_def), do: List.to_tuple(same_def), else: same_def
        case {value1, value2} do
          {^left, ^right} -> true
          {^right, ^left} -> true
          _               -> false
        end
      end
    end)
  end

  defp to_map(list), do: Dict.merge(%{}, list)

  defp filter_nil_values(list) do
    list
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp filter_empty_list([]), do: nil
  defp filter_empty_list(list), do: list

  defp filter_empty_map(map) when map_size(map) == 0, do: nil
  defp filter_empty_map(map), do: map

  defp list_of_checksums(list) do
    list
    |> Enum.map(&inspect(&1))
    |> Enum.map(&checksum(&1))
  end

  defp checksum(string) do
    :crypto.hash(:md5, string)
    |> :erlang.bitstring_to_list
    |> Enum.map(&(:io_lib.format("~2.16.0b", [&1])))
    |> List.flatten
    |> :erlang.list_to_bitstring
  end

  defp only_diff_in_whitespaces(value1, value2) when is_binary(value1) and is_binary(value2) do
    String.strip(value1) == String.strip(value2)
  end
  defp only_diff_in_whitespaces(_, _), do: false

  defp similar_float_binaries(_, _, nil), do: false
  defp similar_float_binaries(value1, value2, accuracy) do
    extract_by_accuracy(value1, accuracy) == extract_by_accuracy(value2, accuracy)
  end

  defp extract_by_accuracy(float_value, accuracy) when is_binary(float_value) do
    case Regex.run(~r/^(\d+\.\d{#{accuracy}})\d*$/, float_value) do
      [_, value] -> value
      _          -> float_value
    end
  end
  defp extract_by_accuracy(value, _accuracy), do: value

end
