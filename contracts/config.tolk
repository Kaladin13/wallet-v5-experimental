type ConfigMap = map<uint8, cell>

fun loadConfigMap(configCell: cell): ConfigMap {
    var configSlice = configCell.beginParse();
    return createMapFromLowLevelDict(configSlice.loadDict());
}
