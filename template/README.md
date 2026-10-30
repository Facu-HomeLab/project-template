# Prompt for Generating a Comprehensive Repository README.md

Copy and paste the prompt below into an AI model (along with your code files, repository structure, or file contents) to generate a complete, professional `README.md` for your project.

---

### Copy Below This Line

```text
Act as a Senior Software Engineer and Technical Writer. Analyze the codebase, configuration files, and project structure provided below to generate an exhaustive, highly structured, and well-documented `README.md` file.

Please follow these instructions and structure when building the `README.md`:

---

### 1. Title & High-Level Overview
- **Project Name**: Clear, descriptive title.
- **Short Tagline**: A concise summary (1-2 sentences) explaining what the project does and the primary problem it solves.
- **Key Features**: Bulleted list highlighting the core functional components and capabilities.

### 2. Architecture & Tech Stack
- **Tech Stack Table/List**: Languages, frameworks, key libraries, databases, and major dependencies used in the project.
- **High-Level Architecture**: Brief summary of how components/modules interact based on the directory structure and main entry points.

### 3. Prerequisites & Dependencies
- System requirements (e.g., Node.js version, Python version, Docker, Rust, Go, database services).
- Necessary API keys, environment variables, or secrets (provide a template format like `.env.example`).

### 4. Getting Started / Local Setup
Provide step-by-step instructions from cloning to running:
1. **Clone repository**: `git clone <repo-url>`
2. **Install dependencies**: Exact command (e.g., `npm install`, `pip install -r requirements.txt`, etc.)
3. **Environment setup**: Copying `.env.example` to `.env` and setting keys.
4. **Build/Development Server**: Exact CLI commands to launch the app locally.

### 5. Usage & Examples
- Provide clear examples of how to run, use, or test the project (CLI commands, API endpoints, UI workflow, etc.).
- Include short code blocks or command snippets illustrating common use cases.

### 6. Project & Directory Structure
- A clean, annotated directory tree showing key folders and files with brief descriptions of their purposes.

### 7. Scripts / Commands Reference
- Table or list of common development scripts available (e.g., `npm test`, `npm run build`, `pytest`, `docker-compose up`).

### 8. Contributing & License
- Basic guidance for submitting issues or pull requests.
- Placeholder for project license (e.g., MIT, Apache 2.0).

---

### Guidance & Tone:
- Keep explanations clear, technical, concise, and professional.
- Use clear Markdown formatting (badges placeholder, code blocks, tables, bold text).
- Avoid vague placeholders where possible—infer details directly from the provided code and configuration files.

---

### Codebase Information / Project Files:

[PASTE YOUR REPOSITORY FILES, FILE TREE, OR CODE SNIPPETS HERE]
```