import json
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

mini_icons = ['WFXM6Earbuds', 'WFXM6EarbudLeft', 'WFXM6EarbudRight', 'WFXM6CaseSymbol', 'WFXM6CaseSymbolFill', 'Earbuds', 'EarbudLeft', 'EarbudRight', 'WFXM5CaseSymbol', 'WFXM5CaseSymbolFill', 'WFXM4Earbuds', 'WFXM4EarbudLeft', 'WFXM4EarbudRight', 'WFXM4CaseSymbol', 'WFXM4CaseSymbolFill', 'WFXM3Earbuds', 'WFXM3EarbudLeft', 'WFXM3EarbudRight', 'WFXM3CaseSymbol', 'WFXM3CaseSymbolFill', 'WF1000XEarbuds', 'WF1000XEarbudLeft', 'WF1000XEarbudRight', 'WF1000XCaseSymbol', 'WF1000XCaseSymbolFill', 'WFL900Earbuds', 'WFL900EarbudLeft', 'WFL900EarbudRight', 'WFL900CaseSymbol', 'WFL900CaseSymbolFill', 'WFLC900Earbuds', 'WFLC900EarbudLeft', 'WFLC900EarbudRight', 'WFLC900CaseSymbol', 'WFLC900CaseSymbolFill', 'WFLS910NEarbuds', 'WFLS910NEarbudLeft', 'WFLS910NEarbudRight', 'WFLS910NCaseSymbol', 'WFLS910NCaseSymbolFill', 'WFL910Earbuds', 'WFL910EarbudLeft', 'WFL910EarbudRight', 'WFL910CaseSymbol', 'WFL910CaseSymbolFill', 'WFLS900NEarbuds', 'WFLS900NEarbudLeft', 'WFLS900NEarbudRight', 'WFLS900NCaseSymbol', 'WFLS900NCaseSymbolFill', 'WFL900UCEarbuds', 'WFL900UCEarbudLeft', 'WFL900UCEarbudRight', 'WFL900UCCaseSymbol', 'WFL900UCCaseSymbolFill', 'WFC500Earbuds', 'WFC500EarbudLeft', 'WFC500EarbudRight', 'WFC500CaseSymbol', 'WFC500CaseSymbolFill', 'WFC510Earbuds', 'WFC510EarbudLeft', 'WFC510EarbudRight', 'WFC510CaseSymbol', 'WFC510CaseSymbolFill', 'WFC700NEarbuds', 'WFC700NEarbudLeft', 'WFC700NEarbudRight', 'WFC700NCaseSymbol', 'WFC700NCaseSymbolFill', 'WFC710NEarbuds', 'WFC710NEarbudLeft', 'WFC710NEarbudRight', 'WFC710NCaseSymbol', 'WFC710NCaseSymbolFill', 'WFH800Earbuds', 'WFH800EarbudLeft', 'WFH800EarbudRight', 'WFH800CaseSymbol', 'WFH800CaseSymbolFill', 'WFSP700NEarbuds', 'WFSP700NEarbudLeft', 'WFSP700NEarbudRight', 'WFSP700NCaseSymbol', 'WFSP700NCaseSymbolFill', 'WFSP800NEarbuds', 'WFSP800NEarbudLeft', 'WFSP800NEarbudRight', 'WFSP800NCaseSymbol', 'WFSP800NCaseSymbolFill', 'WFSP900Earbuds', 'WFSP900EarbudLeft', 'WFSP900EarbudRight', 'WFSP900CaseSymbol', 'WFSP900CaseSymbolFill', 'WHXM6Headphones', 'WHXM5Headphones', 'WHXM4Headphones', 'WHXM4CHeadphones', 'WHXM3Headphones', 'WHXM2Headphones', 'WH1000XXHeadphones', 'WHCH520Headphones', 'WHCH530Headphones', 'WHCH535Headphones', 'WHCH700NHeadphones', 'WHCH720NHeadphones', 'WHCH730NHeadphones', 'WHCH735NHeadphones', 'WHH800Headphones', 'WHH810Headphones', 'WHH900NHeadphones', 'WHH910NHeadphones', 'WHXB700Headphones', 'WHXB900NHeadphones', 'WHXB910NHeadphones', 'WHULT900NHeadphones', 'MDRXB950B1Headphones', 'MDRXB950N1Headphones', 'WI1000XEarbuds', 'WI1000XM2Earbuds', 'WIC100Earbuds', 'WIC600NEarbuds', 'WIH700Earbuds', 'WISP600NEarbuds', 'WFG700NEarbuds', 'WFG700NEarbudLeft', 'WFG700NEarbudRight', 'WFG700NCaseSymbol', 'WFG700NCaseSymbolFill', 'WHG910NHeadphones', 'HTAN7Speaker', 'SRSLS1Speaker', 'SRSNS7Speaker', 'SRSNS7RSpeaker', 'SRSULT10Speaker', 'SRSULT30Speaker', 'SRSULT50Speaker', 'SRSULT70Speaker', 'SRSULT500Speaker', 'SRSULT700Speaker', 'SRSULT900Speaker', 'SRSULT900ACSpeaker', 'SRSULT1000Speaker', 'SRSULT3000Speaker']


def check_vector(path):
    root = ET.parse(path).getroot()
    if root.tag != '{http://www.w3.org/2000/svg}svg':
        raise ValueError(f'Not an SVG vector: {path}')
    for element in root.iter():
        if element.tag.rsplit('}', 1)[-1] not in {'svg', 'g', 'path', 'circle', 'ellipse'}:
            raise ValueError(f'Unclassified vector content: {path}: {element.tag}')
        for key, value in element.attrib.items():
            if key.rsplit('}', 1)[-1] == 'href' or 'url(' in value or 'data:' in value:
                raise ValueError(f'Embedded or linked content: {path}')


def prepare(source, destination, photographs=None):
    source = source.resolve()
    destination = destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Filtered catalog must be outside the source catalog')
    files = [source / 'Contents.json']
    for name in mini_icons:
        folder = source / (name + '.imageset')
        contents = folder / 'Contents.json'
        filenames = {image['filename'] for image in json.loads(contents.read_text())['images']}
        if filenames != {name + '.svg'}:
            raise ValueError(f'Unclassified miniature files: {folder}')
        vector = folder / (name + '.svg')
        check_vector(vector)
        files.extend([contents, vector])
    icon = source.parent / 'AppIcon.icon'
    layers = {'Shells.svg', 'SoftParts.svg'}
    icon_files = {p.relative_to(icon).as_posix() for p in icon.rglob('*') if p.is_file()}
    if icon_files != {'icon.json'} | {'Assets/' + name for name in layers}:
        raise ValueError('Unclassified layered app-icon files')
    images = {layer['image-name'] for group in json.loads((icon / 'icon.json').read_text())['groups']
              for layer in group['layers']}
    if images != layers:
        raise ValueError('Unclassified layered app-icon images')
    for name in layers:
        check_vector(icon / 'Assets' / name)
    for path in files:
        path.read_bytes()
    photo_files = []
    if photographs is not None:
        photographs = photographs.resolve(strict=True)
        if photographs == destination or photographs in destination.parents or destination in photographs.parents:
            raise ValueError('Prepared catalog must be outside the photograph catalog')
        for folder in sorted(photographs.glob('*.imageset')):
            if folder.stem in mini_icons:
                continue
            contents = folder / 'Contents.json'
            if folder.is_symlink() or contents.is_symlink():
                raise ValueError(f'Linked photograph image set: {folder}')
            images = json.loads(contents.read_text())['images']
            image_files = []
            for image in images:
                filename = image.get('filename')
                if filename is None:
                    continue
                if Path(filename).name != filename or Path(filename).suffix.lower() not in {'.png', '.jpg', '.jpeg'}:
                    raise ValueError(f'Invalid photograph filename: {folder}')
                path = folder / filename
                if path.is_symlink():
                    raise ValueError(f'Linked photograph: {path}')
                path.read_bytes()
                image_files.append(path)
            if not image_files:
                raise ValueError(f'No photographs in image set: {folder}')
            photo_files.extend([contents, *image_files])
        if not photo_files:
            raise ValueError('The external catalog contains no product photographs')
    if destination.exists():
        shutil.rmtree(destination)
    for path in files:
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    for path in photo_files:
        target = destination / path.relative_to(photographs)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    return len(mini_icons)


if __name__ == '__main__':
    photographs = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    count = prepare(Path(sys.argv[1]), Path(sys.argv[2]), photographs)
    print(f'Prepared {count} custom miniature image sets; product photographs {"included" if photographs else "excluded"}')
