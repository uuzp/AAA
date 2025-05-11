import ./types
import std/[strformat, strutils, re, os, options, sequtils, streams]

# --- 规则匹配相关函数 ---
proc extractMatch*(s: string, pattern: string): string =
  ## 使用正则表达式从字符串 s 中提取第一个匹配项。
  ## 如果没有匹配，则返回空字符串。
  var matches: array[1, string] # 假设我们只需要捕获组0或整个匹配
  if s.find(re(pattern), matches) != -1:
    return matches[0]
  return ""

proc loadRules*(filename: string): RuleSet =
  ## 从指定文件加载匹配规则。
  ## 文件格式: group1,group2=regex_pattern
  ## 以 # 开头的行或空行将被忽略。
  result = @[]
  if not fileExists(filename):
    echo fmt"警告: 规则文件 '{filename}' 不存在。" # 保持警告
    return
  
  let fileStream = newFileStream(filename, fmRead)
  defer: fileStream.close()

  for line in fileStream.lines:
    let trimmedLine = line.strip()
    if trimmedLine.len == 0 or trimmedLine.startsWith("#"):
      continue

    let parts = trimmedLine.split('=', 1)
    if parts.len < 2:
      echo fmt"警告：规则文件 '{filename}' 中的行格式错误 (缺少 '='): {trimmedLine}" # 保持警告
      continue
    
    let groupsStr = parts[0].strip()
    let patternStr = parts[1].strip()
    
    let groupsSeq = groupsStr.split(',').map(proc(s: string): string = s.strip())
    
    result.add(RuleConfig(
      groups: groupsSeq,
      pattern: patternStr
    ))

proc isPlainString*(s: string): bool =
  ## 检查字符串是否不包含常见的正则表达式元字符。
  ## 用于判断规则中的 pattern 是否可以直接作为字符串匹配。
  const regexMetaChars = {'[', ']', '(', ')', '{', '}', '?', '*', '+', '|', '^', '$', '.', '\\'}
  for c in s:
    if c in regexMetaChars:
      return false
  return true

proc matchRule*(title: string, rule: RuleConfig): Option[string] =
  ## 根据单条规则匹配标题。
  ## 首先检查标题是否包含规则中的任一 group。
  ## 然后，如果 pattern 是普通字符串则直接返回，否则使用正则提取。
  if not rule.groups.anyIt(it in title): # 检查字幕组/关键词是否在标题中
    return none(string)
  
  if isPlainString(rule.pattern): # 如果规则的 pattern 是简单字符串
    return some(rule.pattern) # 直接返回 pattern 作为匹配结果 (通常是番剧名)
  
  # 如果 pattern 是正则表达式
  let extracted = extractMatch(title, rule.pattern)
  if extracted.len > 0:
    # 如果正则提取结果与原标题相同，说明可能规则不精确，但仍视为匹配
    # 否则返回提取到的子串
    return some(extracted) 
  return none(string)

proc findMatchingRule*(title: string, rules: RuleSet): string =
  ## 在规则集中查找第一个与标题匹配的规则，并返回匹配结果 (通常是番剧名)。
  ## 如果没有匹配的规则，则返回空字符串。
  for rule in rules:
    let optMatched = matchRule(title, rule)
    if optMatched.isSome:
      return optMatched.get()
  return ""