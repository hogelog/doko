package search

import (
	"fmt"
	"github.com/google/uuid"
	"github.com/meilisearch/meilisearch-go"
	"time"
)

type Document struct {
	ID        string `json:"id"`
	Timestamp string `json:"timestamp"`
	URL       string `json:"url"`
	Words     []string
}

type Client struct {
	meili *meilisearch.Client
}

func NewClient() *Client {
	meili := meilisearch.NewClient(meilisearch.ClientConfig{
		Host: "http://127.0.0.1:7700",
	})
	return &Client{
		meili: meili,
	}
}

func (client *Client) AddDocument(url string, words []string) {
	index := client.meili.Index("doko")

	res, _ := index.Search(url, &meilisearch.SearchRequest{
		Limit: 10,
	})

	document := Document{
		Timestamp: time.Now().Format(time.RFC3339),
		URL:       url,
		Words:     words,
	}
	if res != nil {
		for _, hit := range res.Hits {
			hitMap := hit.(map[string]interface{})
			if hitMap["url"].(string) == url {
				document.ID = hitMap["id"].(string)
				index.UpdateDocuments([]Document{document}, "id")
				fmt.Println(document)
				return
			}
		}
	}
	id, _ := uuid.NewRandom()
	document.ID = id.String()
	index.AddDocuments([]Document{document})
	fmt.Println(document)
}

func (client *Client) SearchDocuments(word string) []Document {
	index := client.meili.Index("doko")
	res, err := index.Search(word, &meilisearch.SearchRequest{
		Limit: 10,
	})
	if err != nil {
		panic(err)
	}
	documents := make([]Document, len(res.Hits))
	for i, hit := range res.Hits {
		hitMap, ok := hit.(map[string]interface{})
		if !ok {
			panic(ok)
		}
		document := Document{
			ID:        hitMap["id"].(string),
			Timestamp: hitMap["timestamp"].(string),
			URL:       hitMap["url"].(string),
		}
		documents[i] = document
	}
	return documents
}
