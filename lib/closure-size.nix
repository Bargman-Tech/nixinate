{ lib, ... }:
let
  # Parse size strings like "20G", "1024M", "8G" to bytes
  parseSize = str:
    let
      matchResult = builtins.match "([0-9]+)([GMKgmk])?" str;
      num = builtins.fromJSON (builtins.head matchResult);
      suffix = if builtins.length matchResult > 1
               then builtins.elemAt matchResult 1
               else null;
      multiplier = if suffix == "G" || suffix == "g" then 1024*1024*1024
        else if suffix == "M" || suffix == "m" then 1024*1024
        else if suffix == "K" || suffix == "k" then 1024
        else 1; # bytes if no suffix
    in
      num * multiplier;
in
{
  nixinate.lib.parseSize = parseSize;
}
