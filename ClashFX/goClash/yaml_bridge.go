package main

import (
	"strings"

	"gopkg.in/yaml.v3"
)

// marshalYAMLForYams preserves Go string scalars across Swift's YAML 1.1
// resolver. For example, an unquoted REALITY short-id such as 123e4567 can
// otherwise be read as an overflowing float. Actual numeric and boolean
// scalars keep their original types.
func marshalYAMLForYams(value interface{}) ([]byte, error) {
	var root yaml.Node
	if err := root.Encode(value); err != nil {
		return nil, err
	}
	quoteYAMLStringScalars(&root, false)
	return yaml.Marshal(&root)
}

func quoteYAMLStringScalars(node *yaml.Node, mappingKey bool) {
	if node.Kind == yaml.ScalarNode && node.Tag == "!!str" && (!mappingKey || !isSafeYAML11StringKey(node.Value)) {
		node.Style = yaml.DoubleQuotedStyle
	}
	if node.Kind == yaml.MappingNode {
		for index, child := range node.Content {
			quoteYAMLStringScalars(child, index%2 == 0)
		}
		return
	}
	for _, child := range node.Content {
		quoteYAMLStringScalars(child, false)
	}
}

// Leave ordinary configuration keys readable, but quote ambiguous YAML 1.1
// keys too (including user-supplied names and domains used as mapping keys).
func isSafeYAML11StringKey(value string) bool {
	switch strings.ToLower(value) {
	case "", "~", "y", "yes", "n", "no", "true", "false", "on", "off", "null":
		return false
	}
	for index := 0; index < len(value); index++ {
		b := value[index]
		if index == 0 {
			if !((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_') {
				return false
			}
			continue
		}
		if !((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '-') {
			return false
		}
	}
	return true
}
