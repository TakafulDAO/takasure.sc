const fs = require("fs/promises")
const path = require("path")
const archiver = require("archiver")

const outputFolder = path.join(__dirname, "metadata")
const zipFilePath = path.join(__dirname, "metadata.zip")
const baseUrl = "https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME"

async function generateMetadata() {
    try {
        await fs.mkdir(outputFolder, { recursive: true })
    } catch (err) {
        console.error("Error creating folder:", err)
        return
    }

    const promises = []

    for (let tokenId = 0; tokenId < 18000; tokenId++) {
        const tokenStr = tokenId.toString().padStart(5, "0")
        const metadata = {
            description: "TLD Pioneer",
            external_url: "https://thelifedao.io/en",
            image: `${baseUrl}/${tokenStr}.png`,
            name: "TLD Astronaut",
            content: {
                mime: "image/png",
                uri: `${baseUrl}/${tokenStr}.png`,
            },
            atributes: [],
        }
        const filePath = path.join(outputFolder, `${tokenStr}.json`)

        promises.push(fs.writeFile(filePath, JSON.stringify(metadata, null, 2)))

        if (promises.length >= 1000) {
            await Promise.all(promises)
            promises.length = 0 // Reset array
        }
    }

    // Await any remaining promises
    if (promises.length > 0) {
        await Promise.all(promises)
    }

    console.log("Metadata files created.")

    // Now create the zip
    await createZip()
}

async function createZip() {
    const output = require("fs").createWriteStream(zipFilePath)
    const archive = archiver("zip", { zlib: { level: 9 } })

    return new Promise((resolve, reject) => {
        output.on("close", () => {
            console.log(`Created ${zipFilePath} (${archive.pointer()} total bytes)`)
            resolve()
        })

        archive.on("error", (err) => {
            reject(err)
        })

        archive.pipe(output)
        archive.directory(outputFolder, "metadata")
        archive.finalize()
    })
}

generateMetadata().catch(console.error)
