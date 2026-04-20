Unlocking Three Hundred Years of Real Data in Historical Spanish  

Executive Summary (200 words) 

Colonial archives hold centuries of Real Data capable of transforming both historical knowledge and the development of large language models. Yet this immense resource remains locked behind two barriers: noisy Handwritten Text Recognition (HTR) outputs and the linguistic distance between early modern and contemporary Spanish. 

This project will build a proof-of-concept infrastructure that enables machines to process and interpret the Spanish from the sixteenth to the eighteenth century. Using advances in HTR and open-weight Large Language Models (LLMs), we will create a two-step pipeline to convert raw transcriptions into accurate, analysable text. 

The first model, HistClean-SpA, will clean and regularise HTR outputs, producing reliable versions of early modern Spanish while preserving historical features. The second, Hist2Mod-SpA, will standardise those texts into modern Spanish, addressing orthographic, grammatical, and syntactic variation. Both will be trained on a large corpus combining the Relaciones Geográficas (12 volumes) and Mexico’s Archivo General de la Nación (Fondos Marina and Tierras, over 35,000 documents). 

Through collaboration among archaeologists, historians, linguists, engineers, and computer scientists, this project will deliver an open, reproducible pipeline for historical text processing, a foundation for unlocking centuries of Real Data, and a step toward decolonial AI that restores visibility to the voices and knowledge systems of Latin America’s past. 

Executive Summary (100 words) 

Colonial archives preserve centuries of Real Data that could transform historical research and inform AI, yet remain inaccessible due to illegible handwriting and the gap between early modern and contemporary Spanish. This project is a proof-of-concept pilot that develops a two-step AI pipeline to clean and standardize historical Spanish texts from the 16th–18th centuries. HistClean-SpA will correct and regularise HTR text; Hist2Mod-SpA will convert it into modern Spanish. Trained on major Mexican corpora, these models will form an open, reproducible framework for decolonial AI, helping to unlock centuries of knowledge from Latin America’s past. 

 

Challenge Statement and Approach (1000 words) 

1. The research problem 

Across Latin America, colonial archives hold 500 years of history, preserving unparalleled evidence of early modern social, economic, and cultural life. Yet these sources remain largely inaccessible to computational analysis and the public due to three persistent barriers: 

    Reading and transcribing these documents requires palaeographic expertise developed through years of study; 

    This limits the quantity of available material;  

    Early modern Spanish (16th–18th centuries) differs greatly from its modern form. 

As a result, only a small fraction of colonial documents has been transcribed or analysed, since scholars must work through them by hand.  This severely restricts research and leaves most of this Real Data untapped. Our recent work on Handwritten Text Recognition (HTR) has automated the transcription of key historical calligraphies from Latin American archives (Murrieta-Flores et al., 2025), addressing the first two barriers. Yet HTR outputs remain noisy and inconsistent containing character substitutions, missing abbreviations, or irregular spacing, and are not ready for linguistic or computational analysis. 

Moreover, early modern Spanish with its orthographic variability, regional diversity, and grammar, defeats current Natural Language Processing (NLP) tools trained on modern corpora.  

Researchers therefore face two key problems: 
• How to obtain clean, machine-readable corpora that accurately reflect early modern Spanish from noisy HTR transcriptions; and 
• How to produce standardised modern versions of those texts accessible to non-specialists. 

The absence of integrative models linking these stages remains a bottleneck for digital humanities and AI-driven historical analysis. Overcoming this requires AI systems that can see through transcription noise and translate historical language into modern form without losing semantic richness. 

2. The interdisciplinary context 

Recent advances in open-weight Large Language Models (LLMs) such as Mistral-7B, Llama-3-8B, mT5, and ByT5 now allow fine-tuning for specialised historical domains using modest computational resources (Joshi et al., 2024). At the same time, new HTR models for colonial Spanish and Indigenous languages (Murrieta-Flores et al., 2025) are generating vast transcribed corpora, creating an urgent need for automated cleaning and normalisation. 

Digital humanities research has shown that language models can aid palaeographic transcription, semantic annotation, and cultural analysis, but no systematic attempt has yet addressed both cleaning and standardisation for historical Spanish. A promising study by Sarker et al. (2025) advanced this field but relied on a small, homogeneous dataset, limiting generalisability. 

From an AI standpoint, historical corpora—with their spelling irregularities, grammatical shifts, and transcription noise—offer ideal testbeds for innovation in low-resource learning, tokenisation, and diachronic language modelling. 

 

3. Approach and objectives 

Our decolonial approach leverages a broad cross-section of historical documents from multilingual colonial contact zones (ultimately spanning millions of pages) to explore a new two-step solution: first, using AI to see through transcription noise, and second, translating historical language into modern form. If successful, it will unlock vast troves of historical documents for computation, catalysing new humanities research and providing valuable Real Data for advancing AI. 

3.1. HistClean-SpA: Cleaning Model for Historical Spanish 

We will develop a cleaning model based on Mistral-7B-Instruct or Llama-3-8B, fine-tuned using QLoRA for efficiency. This will be combined with a deterministic pre-processing layer to correct predictable HTR artefacts such as character substitutions, abbreviation forms, and irregular spacing. A custom SentencePiece tokenizer will preserve historical graphemes (ñ, ʃ, ç) and abbreviations. 

HistClean-SpA will: 
• Identify and correct typical HTR errors and letter confusions. 
• Expand abbreviations and resolve word segmentation issues. 
• Preserve orthography and syntax while removing transcription noise. 

This will yield a clean, machine-readable version of early modern Spanish suitable for NLP tasks and linguistic analysis. 

3.2. Hist2Mod-SpA: Standardisation Model for Historical-to-Contemporary Spanish 

This model, based on mT5-small or ByT5-small, will convert early modern Spanish into its contemporary equivalent. Trained on HTR/Ground Truth pairs and historical abbreviation dictionaries (e.g., UNAM’s Dictionary of New Spain Abbreviations), it will perform: 
• Orthographic, grammatical, and syntactic modernisation 
• Lexical disambiguation of obsolete forms 
• Controlled transformations under a <STRICT> tag to preserve meaning 

The output will be standardised Spanish, accessible to both humanists and computational tools. 

3.3. Evaluation 

Both models will be trained on a stratified corpus from the 16th–18th centuries, across diverse genres. We will evaluate performance in two stages: 

    Intrinsic metrics: character/word error rates, BLEU, ChrF++, and perplexity 

    Extrinsic tasks: improvements in Named Entity Recognition and topic modelling 

Expert-in-the-loop validation will ensure linguistic and historical accuracy through manual review and annotation. 

 

4. Innovation and previous work 

Past approaches like rule-based methods, character-level models, and lexicon mapping (Bollmann et al., 2011; Bollmann, 2019) operate on small scales and lack generalisability across centuries. In contrast, we can now leverage open-weight LLMs and QLoRA fine-tuning to tackle historical corpora at scale (Joshi et al., 2024). Our team’s recent HTR work on colonial Spanish (Murrieta-Flores et al., 2025) provides a foundation to explore how these noisy outputs can be made usable for research. 

Our project pioneers a dual-model approach addressing two stages of textual transformation: cleaning and standardisation. It also contributes a reusable open corpus of aligned historical–modern text pairs and a shared abbreviation lexicon. From a humanities perspective, linguistic irregularity is treated as data, not error, preserving the heterogeneity of early modern Spanish as a reflection of cultural contact and epistemic hybridity. 

5. Key questions 

• How can AI distinguish transcription errors from authentic variation? 
• What model architectures best capture diachronic syntax and grammar? 
• How much normalisation is appropriate without loss of authenticity? 
• Can this pipeline be adapted to other colonial or multilingual languages? 

6. Expected technical and conceptual contributions 

Technically, the project pioneers low-resource fine-tuning strategies for noisy and historically variable data. Conceptually, it redefines how AI can serve historical interpretation by making it legible. The project frames the colonial archive as a repository of Real Data that capture and preserve the epistemologies of lived experience before the digital era. It demonstrates how AI can recover these materials and builds the groundwork for scalable, decolonial AI in the humanities. 

 

Project Plan and Outcomes (500 words) 

1. Work plan (January – June 2026) 

As a 6-month scoping project, our plan is organized into four rapid phases to develop a minimal viable pipeline, evaluate it, and inform next steps. 

Phase 1 – Preparation (January, Weeks 1–4) 
Conduct a comprehensive data audit and select representative samples from the Relaciones Geográficas and the Archivo General de la Nación (Fondos Marina and Tierras). Create and verify an abbreviation lexicon drawing on UNAM’s Dictionary of New Spain Abbreviations. Evaluate and refine tokenizers to ensure the correct handling of historical graphemes and abbreviations. Prepare dataset for fine-tunning. 

Phase 2 – Model A: HistClean-SpA (February–March, Weeks 5–12) 
Fine-tune Mistral-7B/Llama-3-8B to clean and regularise noisy HTR outputs, combining deterministic pre-processing with parameter-efficient fine-tuning. Evaluate results across diverse samples and integrate iterative feedback from linguists and palaeographers. Deploy a temporary API for internal testing and documentation of the cleaning workflow. 

Phase 3 – Model B: Hist2Mod-SpA (April-May, Weeks 13–21) 
Fine-tune mT5/ByT5 on cleaned data to produce standardised versions in modern Spanish. Test the model on outputs from Phase 2 and conduct linguistic evaluation sessions verifying orthographic, grammatical, and syntactic coherence. Compare model outputs against expert-curated benchmarks and refine based on error analysis. 

Phase 4 – Integration & Evaluation (June, Weeks 22–26) 
Combine both models into a unified end-to-end pipeline linking HTR cleaning with linguistic normalisation. Run intrinsic and extrinsic evaluations using standard NLP metrics (perplexity, BLEU, ChrF++) and research tasks such as Named Entity Recognition. Produce final documentation, prepare preliminary publications, and release code, models, and data under open licences. 

2. Collaboration strategy 

Historians and linguists will define the linguistic rules and review model outputs; computer scientists/engineers will handle model design and fine-tuning; digital humanists will integrate outputs into corpus management and evaluation frameworks. Weekly meetings and shared repositories will ensure transparency and interdisciplinary dialogue. 

3. Deliverables 

    Open-source model weights, tokenizer, and abbreviation lexicon. 

    Documented cleaning and normalisation pipeline for historical Spanish. 

    A public report with findings, evaluation, and recommendations for replication. 

    At least one academic article and one open-access, public-facing publication. 

4. Learning outcomes 

If successful, this project will demonstrate that cleaning and normalising historical corpora can be automated through LLMs while preserving linguistic authenticity. Even if partial, we will learn which tokenization strategies and model architectures fall short and gather data on error patterns. This insight would be invaluable for guiding future attempts and refining the approach. 

5. Potential to Scale 

This project provides a foundation for expanding historical-language processing across Latin America. With additional support, the same workflow used for early modern Spanish can be adapted to low-resource and Indigenous languages that face similar challenges, including limited data, spelling variation, and underrepresentation in current AI systems. The modular structure and efficient training strategy make it possible to extend this method to languages such as Classical Nahuatl, Quechua, or Mayan using smaller datasets. 

Future investment would allow the creation of a platform for multilingual and community-led AI, promoting collaboration among regional institutions and producing open resources for education and research. If this pilot validates our approach, it will provide the justification and groundwork to pursue a larger-scale project (e.g., training a ‘LatAmGPT’ for historical languages) with additional support. 

 

Impact (300 words) 

1. Advancing AI research and availability of Real Data 

Currently, LLMs struggle with noisy, historical data. By developing methods to handle transcription noise and temporal language drift, we push the boundaries of AI robustness and adaptation. This project will serve as a case study in fine-tuning AI on challenging ‘real world’ data, expanding what AI can do beyond clean, modern text. The models will provide new benchmarks for how LLMs can process degraded or non-standard inputs, expanding the understanding of robustness in generative AI.  

2. Advancing humanities research 

For historians and linguists, the ability to automatically clean and standardise millions of lines of historical texts represent transforming manual transcription efforts into scalable analysis. For example, instead of an historian spending months transcribing a single town’s records, they could instantly search and analyse thousands of pages, enabling new questions about colonial administration and Indigenous representation to be answered with evidence at scale. 

3. Societal insight and decolonial technologies 

By enabling machines to read historical Spanish, we recover voices and narratives that modern technology has overlooked. In doing so, we position AI as a tool of knowledge justice, bridging computational innovation with cultural responsibility. This could redefine how technology participates in historical interpretation, empowering Latin American communities to reclaim their documentary heritage. 

 

Team (300 words) 

Prof  – Tec de Monterrey and Lancaster University 
Distinguished Professor of Digital Humanities and Artificial Intelligence at Tecnológico de Monterrey and Chair in Digital Humanities at Lancaster University. Leads conceptual design, interdisciplinary coordination, and dissemination. 

Dr  (Co-PI) – Lancaster University 
Digital humanist and data scientist. Oversees corpus management, evaluation metrics, and pipeline documentation. 

Dr  (Co-PI) – Tec de Monterrey 
Specialist in philology, linguistics, colonial Mexican archives and social history. Guides archival selection and historical interpretation. 

Dr  (Co-PI) – Universidad de Alicante 
Computer scientist expert in machine learning, NLP, and computer vision for cultural data. Co-leads model architecture and training. 

Dr  – Tec de Monterrey 
Senior Research Software Engineer. Manages technical integration, reproducibility, and containerised deployment of the HistClean-SpA and Hist2Mod-SpA pipelines. 

Dr  – Universidad de San Andrés (UDESA) 
Expert in digital humanities and archival technologies. Advises on cleaning workflows, HTR quality, and corpus curation. 

Dr  – Tec de Monterrey (Research Associate 1) 
Colonial historian and linguist. Leads linguistic annotation and orthographic/grammatical analysis. 

Engr  – Tec de Monterrey (Research Associate 2) 
Engineer specialising in LLM deployment and optimisation. Manages integration and testing. 

Engr  - Tec de Monterrey (Research Associate 3) 
Engineer focusing on NLP and model fine-tuning. Supports implementation and benchmarking. 

Dr  – Universidad de Alicante 
Director of the Transducens research group and co-founder of Prompsit Language Engineering. Advises on NLP approaches and model optimisation. 

(Tec-PG), (UNAM-PG) and (Columbia University-UG) 
Assist with corpus cleaning, alignment, abbreviation expansion, and data quality control. 

The project unites expertise across history, archaeology, linguistics, AI, and digital humanities in leading institutions in Mexico, Spain, Colombia, Argentina, and the UK, while fostering international capacity building in Latin America and beyond. 

Budget and Justification (TEMPLATE) 

Duration: January 1 – June 30, 2026 
 

 

 

 

 