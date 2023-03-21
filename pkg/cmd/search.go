package cmd

import (
	"fmt"
	"github.com/hogelog/doko/pkg/search"
	"github.com/spf13/cobra"
)

var searchCmd = &cobra.Command{
	Use:     "search",
	Aliases: []string{"s"},
	Short:   "Search search index",
	Run: func(cmd *cobra.Command, args []string) {
		query := args[0]
		client := search.NewClient()
		documents := client.SearchDocuments(query)
		for _, document := range documents {
			fmt.Println(document)
		}
	},
}

func init() {
	rootCmd.AddCommand(searchCmd)
}
