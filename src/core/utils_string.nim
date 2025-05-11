import ./types
import std/[strutils, options, sequtils] # 添加 sequtils

proc eqIgnoresCase*(a, b: string): bool =
  ## 不区分大小写比较两个字符串是否相等
  return cmpIgnoreCase(a, b) == 0

proc stripLeadingZeros*(s: string): string =
  ## 移除字符串开头的所有 '0' 字符。
  ## 如果字符串全是 '0'，则返回 "0"。
  ## 如果字符串为空或不以 '0' 开头，则返回原字符串。
  if s.len == 0 or s[0] != '0':
    return s
  
  var i = 0
  while i < s.len and s[i] == '0':
    inc i
  
  if i == s.len: # 字符串全是 '0'
    return "0"
  else:
    return s[i .. ^1]
# --- 自然排序辅助函数 ---
proc splitAlphaNumeric*(s: string): seq[string] =
  ## 将字符串分割为交替的非数字和数字序列。
  result = @[]
  if s.len == 0: return
  var currentChunk = ""
  # 确保即使字符串为空，currentIsDigit 也有初始值，尽管在这种情况下循环不会执行
  var currentIsDigit = if s.len > 0: s[0].isDigit() else: false

  for c in s:
    if c.isDigit() == currentIsDigit:
      currentChunk.add(c)
    else:
      if currentChunk.len > 0: result.add(currentChunk) # Add previous chunk
      currentChunk = $c # Start new chunk
      currentIsDigit = c.isDigit()
  
  if currentChunk.len > 0: # Add the very last chunk
    result.add(currentChunk)

proc naturalCompare*(a: LocalFileInfo, b: LocalFileInfo): int =
  ## 自然比较两个 LocalFileInfo 对象的文件名 (nameOnly)。
  let partsA = splitAlphaNumeric(a.nameOnly.toLower()) # 忽略大小写比较
  let partsB = splitAlphaNumeric(b.nameOnly.toLower())

  for i in 0 .. min(partsA.len - 1, partsB.len - 1):
    let partA = partsA[i]
    let partB = partsB[i]

    # 检查块是否可能为数字 (非空且首字符为数字)
    let partAIsPotentiallyNumeric = partA.len > 0 and partA[0].isDigit()
    let partBIsPotentiallyNumeric = partB.len > 0 and partB[0].isDigit()

    if partAIsPotentiallyNumeric and partBIsPotentiallyNumeric:
      var numAOpt: Option[int]
      var numBOpt: Option[int]
      try:
        if partA.all(isDigit): numAOpt = some(parseInt(partA))
      except ValueError: discard # 解析失败则numAOpt保持none
      try:
        if partB.all(isDigit): numBOpt = some(parseInt(partB))
      except ValueError: discard # 解析失败则numBOpt保持none

      if numAOpt.isSome and numBOpt.isSome: # 两者都是有效数字
        let numA = numAOpt.get()
        let numB = numBOpt.get()
        if numA < numB: return -1
        if numA > numB: return 1
        # 数字相同，继续比较下一个部分
      elif numAOpt.isSome: # 只有 A 是数字
        return -1 # 数字通常排在文本前
      elif numBOpt.isSome: # 只有 B 是数字
        return 1  # 数字通常排在文本前
      else: # 两者都不是有效数字（可能是 "0abc" 或解析失败），按文本比较
        if partA < partB: return -1
        if partA > partB: return 1
    else: # 非数字部分的文本比较
      if partA < partB: return -1
      if partA > partB: return 1
  
  # 如果一个是另一个的前缀 (例如 "file" vs "file1")
  if partsA.len < partsB.len: return -1
  if partsA.len > partsB.len: return 1
  
  # 如果文件名部分完全相同，可以比较后缀名作为次要排序依据
  let extComp = cmp(a.ext.toLower(), b.ext.toLower())
  if extComp != 0: return extComp

  return 0